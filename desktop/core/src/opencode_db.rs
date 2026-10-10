//! Read-only access to OpenCode's SQLite database (`opencode.db`).
//!
//! OpenCode keeps every session in one database whose layout is not a public API, so any failure
//! here (locked, corrupt, schema mismatch) leaves the database unread until its next change. The
//! message `data` column is JSON: only the fixed set of paths listed in the metrics contract is
//! extracted in SQL with `json_extract`, so prompts, responses and everything else in it never
//! leave SQLite. The `part` table and every other column are never selected. Every value is
//! bounded in SQL as well (an id or text over its limit never leaves SQLite), and a read stops at
//! a byte budget, so a database cannot make a read hold more than a fixed amount of memory.

use crate::sqlite_read::open_read_only;
use rusqlite::types::Value;
use rusqlite::Connection;
use std::collections::HashSet;
use std::path::Path;

/// More messages than this in the retention window are not held in memory: the newest win.
pub(crate) const MAX_MESSAGES: usize = 200_000;
const MAX_SESSIONS: usize = 100_000;
/// A single token count above this is not a real usage figure.
const MAX_TOKEN_COUNT: i64 = 100_000_000;
const SESSION_FETCH_CHUNK: usize = 400;
/// How many generations of ancestors of a session are looked up (subagent chains are short).
const MAX_ANCESTOR_ROUNDS: usize = 16;
const MAX_IDENTIFIER_BYTES: usize = 120;
/// Longest row id, session id or parent id read, in characters (the bound of the other sources'
/// ids). A message or session with a longer one is skipped; a longer parent id never reads as "no
/// parent", which would turn a subagent session into a primary one.
const MAX_ID_CHARS: usize = 512;
/// Longest role, model, provider, variant, finish, error name, version or number read, in
/// characters. Nothing legitimate is longer; longer text is read as absent (a number as invalid).
const MAX_VALUE_CHARS: usize = 200;
/// A read stops after this many bytes of values, keeping the newest messages like
/// [`MAX_MESSAGES`] does.
const MAX_READ_BYTES: usize = 64 * 1_048_576;

/// One row of `session`: only what decides whether and how its messages are measured.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct SessionRow {
    pub id: String,
    /// A non-null parent marks a subagent (task tool) session.
    pub parent_id: Option<String>,
    pub version: String,
}

/// An assistant message: one model call (one OpenCode step).
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct Assistant {
    /// The user message this call answers.
    pub parent_id: Option<String>,
    pub model: Option<String>,
    pub provider: Option<String>,
    pub variant: Option<String>,
    pub finish: Option<String>,
    /// `error.name` is present (for example `MessageAbortedError`).
    pub failed: bool,
    /// `error.name` is `APIError`: the provider's API refused or failed the call.
    pub api_error: bool,
    /// `error.data.statusCode` of an API error; `None` when absent or not a usable number.
    pub error_status: Option<i64>,
    pub created_ms: i64,
    pub completed_ms: Option<i64>,
    /// `tokens.output + tokens.reasoning`.
    pub output_tokens: i64,
    pub reasoning_tokens: i64,
    /// `tokens.input` (uncached) and `tokens.cache.read`; `None` when not a usable number.
    pub input_tokens: Option<i64>,
    pub cache_read_tokens: Option<i64>,
    /// `tokens.cache.write`; absent counts as 0 where it is used.
    pub cache_write_tokens: Option<i64>,
    /// A token count or the start time is not a valid value: the message cannot be measured.
    pub malformed: bool,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) enum MessageKind {
    /// A user message starts a turn at its `time.created`.
    User {
        created_ms: i64,
    },
    Assistant(Box<Assistant>),
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct MessageRow {
    pub id: String,
    pub session_id: String,
    pub updated_ms: i64,
    pub kind: MessageKind,
}

/// Which messages a read takes.
#[derive(Clone, Copy, Debug)]
pub(crate) enum MessageScope {
    /// Everything created at or after this time (milliseconds since the epoch).
    CreatedSince(i64),
    /// Everything updated at or after this time, restricted to messages created at or after
    /// `created_since`.
    UpdatedSince { updated: i64, created_since: i64 },
}

/// What one read returned.
#[derive(Debug, Default)]
pub(crate) struct Read {
    pub messages: Vec<MessageRow>,
    /// Session rows: all of them on a full read, otherwise those that were asked for.
    pub sessions: Vec<SessionRow>,
    /// Approximate bytes of values read.
    pub bytes_read: usize,
}

/// The session ids a read must fetch rows for because the index does not have them yet.
pub(crate) type SessionLookup<'a> = &'a dyn Fn(&str) -> bool;

/// The values of a message row. Each JSON path is extracted once, here, and bounded where the
/// result is selected by [`message_columns`].
const MESSAGE_FIELDS: &str = "m.id AS id, m.session_id AS session_id, \
    m.time_created AS time_created, m.time_updated AS time_updated, \
    json_extract(m.data, '$.role') AS role, json_extract(m.data, '$.parentID') AS parent_id, \
    json_extract(m.data, '$.modelID') AS model, json_extract(m.data, '$.providerID') AS provider, \
    json_extract(m.data, '$.variant') AS variant, json_extract(m.data, '$.finish') AS finish, \
    json_extract(m.data, '$.error.name') AS error_name, \
    json_extract(m.data, '$.error.data.statusCode') AS error_status, \
    json_extract(m.data, '$.time.created') AS created, \
    json_extract(m.data, '$.time.completed') AS completed, \
    json_extract(m.data, '$.tokens.output') AS output, \
    json_extract(m.data, '$.tokens.reasoning') AS reasoning, \
    json_extract(m.data, '$.tokens.input') AS input, \
    json_extract(m.data, '$.tokens.cache.read') AS cache_read, \
    json_extract(m.data, '$.tokens.cache.write') AS cache_write";

/// The columns [`decode_message`] reads, each bounded: text is NULL when longer than
/// [`MAX_VALUE_CHARS`] (an id: [`MAX_ID_CHARS`]), a number is an empty string, which is not a
/// number, so a value too long to be one stays invalid instead of reading as absent.
fn message_columns() -> String {
    let text =
        |column: &str, max: usize| format!("CASE WHEN length({column}) <= {max} THEN {column} END");
    let number = |column: &str| {
        format!("CASE WHEN {column} IS NULL OR length({column}) <= {MAX_VALUE_CHARS} THEN {column} ELSE '' END")
    };
    let integer =
        |column: &str| format!("CASE WHEN typeof({column}) = 'integer' THEN {column} END");
    [
        "id".to_owned(),
        "session_id".to_owned(),
        integer("time_created"),
        integer("time_updated"),
        text("role", MAX_VALUE_CHARS),
        text("parent_id", MAX_ID_CHARS),
        text("model", MAX_VALUE_CHARS),
        text("provider", MAX_VALUE_CHARS),
        text("variant", MAX_VALUE_CHARS),
        text("finish", MAX_VALUE_CHARS),
        // Only whether a non-empty name is present is used.
        "CASE WHEN typeof(error_name) = 'text' AND length(error_name) > 0 THEN 1 ELSE 0 END"
            .to_owned(),
        number("created"),
        number("completed"),
        number("output"),
        number("reasoning"),
        number("input"),
        number("cache_read"),
        number("cache_write"),
        // Of the error only its name's equality with `APIError` and its HTTP status leave SQLite,
        // never its message.
        "CASE WHEN error_name = 'APIError' THEN 1 ELSE 0 END".to_owned(),
        number("error_status"),
    ]
    .join(", ")
}

/// The columns of a session and the conditions that bound them. A session whose id or parent id is
/// too long is skipped, and so are its messages. A version that is too long reads as empty: the
/// session stays in the tree but is not measured.
fn session_query(condition: &str) -> String {
    format!(
        "SELECT id, CASE WHEN typeof(parent_id) = 'text' THEN parent_id END, \
         CASE WHEN typeof(version) = 'text' THEN \
         CASE WHEN length(version) <= {MAX_VALUE_CHARS} THEN version ELSE '' END END \
         FROM session WHERE typeof(id) = 'text' AND length(id) <= {MAX_ID_CHARS} \
         AND (typeof(parent_id) != 'text' OR length(parent_id) <= {MAX_ID_CHARS}) AND {condition}"
    )
}

/// Opens the database read-only and reads messages in one transaction. With `full`, every session
/// row is read too; otherwise only the sessions the new messages name that `known` does not have.
pub(crate) fn read_database(
    path: &Path,
    scope: MessageScope,
    full: bool,
    known: SessionLookup,
) -> rusqlite::Result<Read> {
    read_database_within(path, scope, full, known, Limits::DEFAULT)
}

/// What one read may hold: values up to `bytes` in all (messages and sessions together) and at
/// most `sessions` session rows, whether read in full or looked up as ancestors.
#[derive(Clone, Copy, Debug)]
pub(crate) struct Limits {
    pub bytes: usize,
    pub sessions: usize,
}

impl Limits {
    /// Whether `read` already holds as much as the limits allow.
    fn exhausted_by(&self, read: &Read) -> bool {
        read.sessions.len() >= self.sessions || read.bytes_read >= self.bytes
    }

    pub const DEFAULT: Self = Self {
        bytes: MAX_READ_BYTES,
        sessions: MAX_SESSIONS,
    };
}

/// [`read_database`] with its own limits: messages and sessions are read, newest messages first,
/// until their values add up to `limits.bytes`, and no more than `limits.sessions` session rows.
pub(crate) fn read_database_within(
    path: &Path,
    scope: MessageScope,
    full: bool,
    known: SessionLookup,
    limits: Limits,
) -> rusqlite::Result<Read> {
    let mut connection = open_read_only(path)?;
    let transaction = connection.transaction()?;
    let mut read = Read::default();
    read_messages(&transaction, scope, &mut read, limits.bytes)?;
    if full {
        read_all_sessions(&transaction, &mut read, limits)?;
    } else {
        // Sessions the new messages name, and the ancestors of those, until nothing is missing or
        // a limit is reached. Every session asked for once is remembered, so a shared ancestor is
        // asked for once.
        let mut asked: HashSet<String> = HashSet::new();
        let mut wanted: Vec<String> = Vec::new();
        for message in &read.messages {
            if !known(&message.session_id) && asked.insert(message.session_id.clone()) {
                wanted.push(message.session_id.clone());
            }
        }
        for _ in 0..MAX_ANCESTOR_ROUNDS {
            if wanted.is_empty() {
                break;
            }
            let first_new = read.sessions.len();
            read_sessions(&transaction, &wanted, &mut read, limits)?;
            wanted = read.sessions[first_new..]
                .iter()
                .filter_map(|session| session.parent_id.as_ref())
                .filter(|parent| !known(parent) && asked.insert((*parent).clone()))
                .cloned()
                .collect();
            wanted.sort();
        }
    }
    Ok(read)
}

fn read_messages(
    connection: &Connection,
    scope: MessageScope,
    read: &mut Read,
    max_bytes: usize,
) -> rusqlite::Result<()> {
    // `json_valid` keeps one corrupt row from failing the whole statement.
    let (filter, first, second) = match scope {
        MessageScope::CreatedSince(created) => ("m.time_created >= ?1", created, 0),
        MessageScope::UpdatedSince {
            updated,
            created_since,
        } => (
            "m.time_updated >= ?1 AND m.time_created >= ?2",
            updated,
            created_since,
        ),
    };
    let sql = format!(
        "SELECT {columns} FROM (SELECT {MESSAGE_FIELDS} FROM message m WHERE {filter} \
         AND json_valid(m.data) AND length(m.id) <= {MAX_ID_CHARS} \
         AND length(m.session_id) <= {MAX_ID_CHARS} ORDER BY m.time_created DESC LIMIT {limit}) \
         ORDER BY time_created DESC",
        columns = message_columns(),
        limit = MAX_MESSAGES + 1,
    );
    let mut statement = connection.prepare(&sql)?;
    let mut rows = match scope {
        MessageScope::CreatedSince(_) => statement.query(rusqlite::params![first])?,
        MessageScope::UpdatedSince { .. } => statement.query(rusqlite::params![first, second])?,
    };
    while let Some(row) = rows.next()? {
        if read.messages.len() >= MAX_MESSAGES || read.bytes_read >= max_bytes {
            break;
        }
        let values: Vec<Value> = (0..20)
            .map(|index| row.get::<_, Value>(index))
            .collect::<rusqlite::Result<_>>()?;
        read.bytes_read += values.iter().map(approximate_size).sum::<usize>();
        if let Some(message) = decode_message(&values) {
            read.messages.push(message);
        }
    }
    Ok(())
}

fn read_all_sessions(
    connection: &Connection,
    read: &mut Read,
    limits: Limits,
) -> rusqlite::Result<()> {
    let mut statement = connection.prepare(&format!(
        "{} LIMIT {}",
        session_query("1"),
        limits.sessions + 1
    ))?;
    let mut rows = statement.query([])?;
    while let Some(row) = rows.next()? {
        if limits.exhausted_by(read) {
            break;
        }
        if let Some(session) = decode_session(&row.get::<_, Value>(0)?, &row.get(1)?, &row.get(2)?)
        {
            read.bytes_read += session.id.len() + session.version.len() + 16;
            read.sessions.push(session);
        }
    }
    Ok(())
}

/// Appends the sessions with these ids to `read`, until a limit is reached.
fn read_sessions(
    connection: &Connection,
    ids: &[String],
    read: &mut Read,
    limits: Limits,
) -> rusqlite::Result<()> {
    for chunk in ids.chunks(SESSION_FETCH_CHUNK) {
        if limits.exhausted_by(read) {
            break;
        }
        let placeholders = vec!["?"; chunk.len()].join(",");
        let mut statement =
            connection.prepare(&session_query(&format!("id IN ({placeholders})")))?;
        let mut rows = statement.query(rusqlite::params_from_iter(chunk.iter()))?;
        while let Some(row) = rows.next()? {
            if limits.exhausted_by(read) {
                break;
            }
            if let Some(session) =
                decode_session(&row.get::<_, Value>(0)?, &row.get(1)?, &row.get(2)?)
            {
                read.bytes_read += session.id.len() + session.version.len() + 16;
                read.sessions.push(session);
            }
        }
    }
    Ok(())
}

fn approximate_size(value: &Value) -> usize {
    match value {
        Value::Text(text) => text.len(),
        Value::Blob(blob) => blob.len(),
        Value::Integer(_) | Value::Real(_) => 8,
        Value::Null => 0,
    }
}

fn decode_session(id: &Value, parent: &Value, version: &Value) -> Option<SessionRow> {
    let (Value::Text(id), Value::Text(version)) = (id, version) else {
        return None;
    };
    Some(SessionRow {
        id: id.clone(),
        parent_id: match parent {
            Value::Text(parent) if !parent.is_empty() => Some(parent.clone()),
            _ => None,
        },
        version: version.clone(),
    })
}

fn text(value: &Value) -> Option<String> {
    match value {
        Value::Text(text) if !text.is_empty() => Some(text.clone()),
        _ => None,
    }
}

/// A model, provider or variant id kept only when it is a short plain identifier.
fn identifier(value: &Value) -> Option<String> {
    text(value).filter(|value| {
        value.len() <= MAX_IDENTIFIER_BYTES
            && value.bytes().all(|byte| {
                byte.is_ascii_alphanumeric()
                    || matches!(byte, b'.' | b'_' | b'-' | b'+' | b'/' | b':' | b'@')
            })
    })
}

/// A JSON integer from `json_extract`: `Ok(None)` when absent, `Err` for any other type.
fn integer(value: &Value) -> Result<Option<i64>, ()> {
    match value {
        Value::Null => Ok(None),
        Value::Integer(number) => Ok(Some(*number)),
        _ => Err(()),
    }
}

/// A token count: absent is `None`; a negative, non-integer or oversized value is invalid.
fn token_count(value: &Value) -> Result<Option<i64>, ()> {
    match integer(value)? {
        Some(count) if !(0..=MAX_TOKEN_COUNT).contains(&count) => Err(()),
        other => Ok(other),
    }
}

fn decode_message(values: &[Value]) -> Option<MessageRow> {
    let id = text(&values[0])?;
    let session_id = text(&values[1])?;
    let Value::Integer(updated_ms) = values[3] else {
        return None;
    };
    let Value::Integer(row_created_ms) = values[2] else {
        return None;
    };
    let created_ms = integer(&values[11]).ok().flatten();
    let kind = match values[4] {
        Value::Text(ref role) if role == "user" => MessageKind::User {
            created_ms: created_ms.unwrap_or(row_created_ms),
        },
        Value::Text(ref role) if role == "assistant" => {
            let output = token_count(&values[13]);
            let reasoning = token_count(&values[14]);
            let input = token_count(&values[15]).ok().flatten();
            let cache_read = token_count(&values[16]).ok().flatten();
            let cache_write = token_count(&values[17]).ok().flatten();
            let completed = integer(&values[12]);
            let malformed =
                output.is_err() || reasoning.is_err() || completed.is_err() || created_ms.is_none();
            let output = output.ok().flatten().unwrap_or(0);
            let reasoning = reasoning.ok().flatten().unwrap_or(0);
            MessageKind::Assistant(Box::new(Assistant {
                parent_id: text(&values[5]),
                model: identifier(&values[6]),
                provider: identifier(&values[7]),
                variant: identifier(&values[8]),
                finish: text(&values[9]),
                failed: matches!(values[10], Value::Integer(1)),
                api_error: matches!(values[18], Value::Integer(1)),
                error_status: integer(&values[19]).ok().flatten(),
                created_ms: created_ms.unwrap_or(row_created_ms),
                completed_ms: completed.ok().flatten(),
                output_tokens: output.saturating_add(reasoning),
                reasoning_tokens: reasoning,
                input_tokens: input,
                cache_read_tokens: cache_read,
                cache_write_tokens: cache_write,
                malformed,
            }))
        }
        _ => return None,
    };
    Some(MessageRow {
        id,
        session_id,
        updated_ms,
        kind,
    })
}
