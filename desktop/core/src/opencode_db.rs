//! Read-only access to OpenCode's SQLite database (`opencode.db`).
//!
//! OpenCode keeps every session in one database whose layout is not a public API, so any failure
//! here (locked, corrupt, schema mismatch) leaves the database unread until its next change. The
//! message `data` column is JSON: only the fixed set of paths listed in the metrics contract is
//! extracted in SQL with `json_extract`, so prompts, responses and everything else in it never
//! leave SQLite. The `part` table and every other column are never selected.

use crate::sqlite_read::open_read_only;
use rusqlite::types::Value;
use rusqlite::Connection;
use std::path::Path;

/// More messages than this in the retention window are not held in memory: the newest win.
pub(crate) const MAX_MESSAGES: usize = 200_000;
const MAX_SESSIONS: usize = 100_000;
/// A single token count above this is not a real usage figure.
const MAX_TOKEN_COUNT: i64 = 100_000_000;
const SESSION_FETCH_CHUNK: usize = 400;
const MAX_IDENTIFIER_BYTES: usize = 120;

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

const MESSAGE_COLUMNS: &str = "m.id, m.session_id, m.time_created, m.time_updated, \
    json_extract(m.data, '$.role'), json_extract(m.data, '$.parentID'), \
    json_extract(m.data, '$.modelID'), json_extract(m.data, '$.providerID'), \
    json_extract(m.data, '$.variant'), json_extract(m.data, '$.finish'), \
    json_extract(m.data, '$.error.name'), json_extract(m.data, '$.time.created'), \
    json_extract(m.data, '$.time.completed'), json_extract(m.data, '$.tokens.output'), \
    json_extract(m.data, '$.tokens.reasoning'), json_extract(m.data, '$.tokens.input'), \
    json_extract(m.data, '$.tokens.cache.read'), json_extract(m.data, '$.tokens.cache.write')";

/// Opens the database read-only and reads messages in one transaction. With `full`, every session
/// row is read too; otherwise only the sessions the new messages name that `known` does not have.
pub(crate) fn read_database(
    path: &Path,
    scope: MessageScope,
    full: bool,
    known: SessionLookup,
) -> rusqlite::Result<Read> {
    let mut connection = open_read_only(path)?;
    let transaction = connection.transaction()?;
    let mut read = Read::default();
    read_messages(&transaction, scope, &mut read)?;
    if full {
        read_all_sessions(&transaction, &mut read)?;
    } else {
        // Sessions the new messages name, and the ancestors of those, until nothing is missing.
        let mut wanted: Vec<String> = Vec::new();
        for message in &read.messages {
            if !known(&message.session_id) && !wanted.contains(&message.session_id) {
                wanted.push(message.session_id.clone());
            }
        }
        for _ in 0..16 {
            if wanted.is_empty() {
                break;
            }
            let fetched = read_sessions(&transaction, &wanted, &mut read.bytes_read)?;
            wanted = fetched
                .iter()
                .filter_map(|session| session.parent_id.clone())
                .filter(|parent| !known(parent) && !read.sessions.iter().any(|s| &s.id == parent))
                .collect();
            wanted.sort();
            wanted.dedup();
            read.sessions.extend(fetched);
        }
    }
    Ok(read)
}

fn read_messages(
    connection: &Connection,
    scope: MessageScope,
    read: &mut Read,
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
        "SELECT {MESSAGE_COLUMNS} FROM message m WHERE {filter} AND json_valid(m.data) \
         ORDER BY m.time_created DESC LIMIT {limit}",
        limit = MAX_MESSAGES + 1,
    );
    let mut statement = connection.prepare(&sql)?;
    let mut rows = match scope {
        MessageScope::CreatedSince(_) => statement.query(rusqlite::params![first])?,
        MessageScope::UpdatedSince { .. } => statement.query(rusqlite::params![first, second])?,
    };
    while let Some(row) = rows.next()? {
        if read.messages.len() >= MAX_MESSAGES {
            break;
        }
        let values: Vec<Value> = (0..18)
            .map(|index| row.get::<_, Value>(index))
            .collect::<rusqlite::Result<_>>()?;
        read.bytes_read += values.iter().map(approximate_size).sum::<usize>();
        if let Some(message) = decode_message(&values) {
            read.messages.push(message);
        }
    }
    Ok(())
}

fn read_all_sessions(connection: &Connection, read: &mut Read) -> rusqlite::Result<()> {
    let mut statement = connection.prepare(&format!(
        "SELECT id, parent_id, version FROM session LIMIT {}",
        MAX_SESSIONS + 1
    ))?;
    let mut rows = statement.query([])?;
    while let Some(row) = rows.next()? {
        if read.sessions.len() >= MAX_SESSIONS {
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

fn read_sessions(
    connection: &Connection,
    ids: &[String],
    bytes_read: &mut usize,
) -> rusqlite::Result<Vec<SessionRow>> {
    let mut found = Vec::new();
    for chunk in ids.chunks(SESSION_FETCH_CHUNK) {
        let placeholders = vec!["?"; chunk.len()].join(",");
        let mut statement = connection.prepare(&format!(
            "SELECT id, parent_id, version FROM session WHERE id IN ({placeholders})"
        ))?;
        let mut rows = statement.query(rusqlite::params_from_iter(chunk.iter()))?;
        while let Some(row) = rows.next()? {
            if let Some(session) =
                decode_session(&row.get::<_, Value>(0)?, &row.get(1)?, &row.get(2)?)
            {
                *bytes_read += session.id.len() + session.version.len() + 16;
                found.push(session);
            }
        }
    }
    Ok(found)
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
                failed: text(&values[10]).is_some(),
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
