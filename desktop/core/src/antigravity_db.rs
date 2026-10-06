//! Read-only access to an Antigravity conversation database.
//!
//! Antigravity keeps one SQLite database per conversation. Its layout is not a public API, so
//! every failure here (locked, corrupt, schema mismatch, undecodable blob) is reported as
//! unreadable and the caller skips the database until its next change. Only the columns the
//! metrics contract allows are selected, and only numeric usage, timestamps, model ids, the
//! effort suffix and execution ids are decoded from them.

use crate::protobuf::{Malformed, Message};
use chrono::{DateTime, Utc};
use rusqlite::types::Value;
use rusqlite::{Connection, OpenFlags};
use std::collections::HashMap;
use std::path::Path;
use std::time::Duration;

const MAX_STEPS: usize = 100_000;
const MAX_EXECUTORS: usize = 10_000;
const MAX_GENERATIONS: usize = 100_000;
/// A blob above this size is treated as unreadable instead of being loaded.
const MAX_BLOB_BYTES: i64 = 8 * 1_048_576;
const BUSY_TIMEOUT: Duration = Duration::from_millis(500);

/// Why a database was skipped for this poll.
#[derive(Debug)]
pub(crate) enum ReadError {
    Sqlite,
    /// A table holds more rows than Tokrate is willing to hold in memory.
    TooLarge,
    /// A step's metadata is not a readable message, so the steps cannot be attributed safely.
    Undecodable,
    /// The path cannot be expressed as a `file:` URI.
    Path,
}

impl From<rusqlite::Error> for ReadError {
    fn from(_: rusqlite::Error) -> Self {
        Self::Sqlite
    }
}

/// Token usage of one model call (`steps.metadata` field 9).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) struct Usage {
    pub output_tokens: i64,
    pub thinking_tokens: i64,
}

#[derive(Clone, Debug, PartialEq)]
pub(crate) struct Step {
    pub idx: i64,
    pub has_subtrajectory: bool,
    pub execution_id: Option<String>,
    /// Join key into `gen_metadata.idx`; proto3 omits 0.
    pub generation: i64,
    pub created: Option<DateTime<Utc>>,
    pub completed: Option<DateTime<Utc>>,
    /// Present for a model call.
    pub usage: Option<Usage>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct Executor {
    pub id: String,
    /// Execution state; proto3 omits 0.
    pub state: u64,
    pub variant: Option<String>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct Generation {
    pub model: Option<String>,
    /// The generation carries `used_non_gemini_model` and every such pair says `false`.
    pub gemini_only: bool,
}

/// Everything Tokrate reads from one database in one consistent snapshot.
#[derive(Debug, Default)]
pub(crate) struct Snapshot {
    pub steps: Vec<Step>,
    pub executors: Vec<Executor>,
    pub generations: HashMap<i64, Generation>,
    /// Any `parent_references` row marks a subagent trajectory.
    pub is_subagent: bool,
    /// Bytes of blob content read from the database.
    pub bytes_read: usize,
}

/// The `file:` URI of a database path with `mode=ro`. The path is percent-encoded; Windows drive
/// paths become `file:///C:/...` and backslashes become slashes.
pub(crate) fn read_only_uri(path: &Path) -> Option<String> {
    let text = path.to_str()?.replace('\\', "/");
    let mut encoded = String::with_capacity(text.len() + 24);
    encoded.push_str("file://");
    if !text.starts_with('/') {
        encoded.push('/');
    }
    let bytes = text.as_bytes();
    for (index, byte) in bytes.iter().enumerate() {
        let drive_colon =
            *byte == b':' && index == 1 && bytes[0].is_ascii_alphabetic() && !text.starts_with('/');
        if byte.is_ascii_alphanumeric()
            || matches!(byte, b'-' | b'.' | b'_' | b'~' | b'/')
            || drive_colon
        {
            encoded.push(*byte as char);
        } else {
            encoded.push_str(&format!("%{byte:02X}"));
        }
    }
    encoded.push_str("?mode=ro");
    Some(encoded)
}

/// Reads one database. Never writes: the connection is read-only, honours the write-ahead log
/// (no `immutable`) and waits at most half a second for a lock.
pub(crate) fn read_database(path: &Path) -> Result<Snapshot, ReadError> {
    let uri = read_only_uri(path).ok_or(ReadError::Path)?;
    let flags = OpenFlags::SQLITE_OPEN_READ_ONLY
        | OpenFlags::SQLITE_OPEN_URI
        | OpenFlags::SQLITE_OPEN_NO_MUTEX;
    let mut connection = Connection::open_with_flags(uri, flags)?;
    connection.busy_timeout(BUSY_TIMEOUT)?;
    // One read transaction so steps, executions and generations belong together.
    let transaction = connection.transaction()?;
    let mut snapshot = Snapshot {
        is_subagent: transaction.query_row(
            "SELECT EXISTS(SELECT 1 FROM parent_references)",
            [],
            |row| row.get::<_, i64>(0),
        )? != 0,
        ..Snapshot::default()
    };
    if snapshot.is_subagent {
        return Ok(snapshot);
    }

    let mut statement = transaction.prepare(
        "SELECT idx, has_subtrajectory, \
         CASE WHEN length(metadata) <= ?1 THEN metadata END, length(metadata) \
         FROM steps ORDER BY idx LIMIT ?2",
    )?;
    let mut rows = statement.query(rusqlite::params![MAX_BLOB_BYTES, MAX_STEPS as i64 + 1])?;
    while let Some(row) = rows.next()? {
        if snapshot.steps.len() >= MAX_STEPS {
            return Err(ReadError::TooLarge);
        }
        let (idx, flag, blob, length): (Option<i64>, Value, Option<Vec<u8>>, Option<i64>) =
            (row.get(0)?, row.get(1)?, row.get(2)?, row.get(3)?);
        let Some(idx) = idx else { continue };
        let blob = match (blob, length) {
            (Some(blob), _) => blob,
            // No metadata at all: the step cannot belong to an execution.
            (None, None) => continue,
            // Present but over the cap.
            (None, Some(_)) => return Err(ReadError::Undecodable),
        };
        snapshot.bytes_read += blob.len();
        let step = decode_step(idx, truthy(&flag), &blob).ok_or(ReadError::Undecodable)?;
        snapshot.steps.push(step);
    }
    drop(rows);
    drop(statement);

    let mut statement = transaction.prepare(
        "SELECT CASE WHEN length(data) <= ?1 THEN data END FROM executor_metadata LIMIT ?2",
    )?;
    let mut rows = statement.query(rusqlite::params![MAX_BLOB_BYTES, MAX_EXECUTORS as i64 + 1])?;
    let mut seen = 0;
    while let Some(row) = rows.next()? {
        seen += 1;
        if seen > MAX_EXECUTORS {
            return Err(ReadError::TooLarge);
        }
        let Some(blob) = row.get::<_, Option<Vec<u8>>>(0)? else {
            continue;
        };
        snapshot.bytes_read += blob.len();
        // An unreadable executor row leaves its execution unfinished as far as Tokrate knows.
        if let Some(executor) = decode_executor(&blob) {
            snapshot.executors.push(executor);
        }
    }
    drop(rows);
    drop(statement);

    let mut statement = transaction.prepare(
        "SELECT idx, CASE WHEN length(data) <= ?1 THEN data END FROM gen_metadata LIMIT ?2",
    )?;
    let mut rows = statement.query(rusqlite::params![
        MAX_BLOB_BYTES,
        MAX_GENERATIONS as i64 + 1
    ])?;
    let mut seen = 0;
    while let Some(row) = rows.next()? {
        seen += 1;
        if seen > MAX_GENERATIONS {
            return Err(ReadError::TooLarge);
        }
        let (Some(idx), Some(blob)) = (
            row.get::<_, Option<i64>>(0)?,
            row.get::<_, Option<Vec<u8>>>(1)?,
        ) else {
            continue;
        };
        snapshot.bytes_read += blob.len();
        // An unreadable generation leaves its model calls without a model.
        if let Some(generation) = decode_generation(&blob) {
            snapshot.generations.insert(idx, generation);
        }
    }
    Ok(snapshot)
}

/// SQLite's `numeric` column: any non-zero number, or the text `true`/`1`, is true.
fn truthy(value: &Value) -> bool {
    match value {
        Value::Integer(number) => *number != 0,
        Value::Real(number) => *number != 0.0,
        Value::Text(text) => matches!(text.trim().to_ascii_lowercase().as_str(), "true" | "1"),
        Value::Null | Value::Blob(_) => false,
    }
}

fn decode_step(idx: i64, has_subtrajectory: bool, blob: &[u8]) -> Option<Step> {
    let message = Message::parse(blob)?;
    let step = (|| -> Result<Step, Malformed> {
        let usage = match message.message(9)? {
            Some(usage) => Some(Usage {
                output_tokens: token_count(&usage, 3)?,
                thinking_tokens: token_count(&usage, 9)?,
            }),
            None => None,
        };
        Ok(Step {
            idx,
            has_subtrajectory,
            execution_id: message.string(12)?.map(str::to_owned),
            // A missing 20.3 is generation 0.
            generation: match message.message(20)? {
                Some(generation) => {
                    i64::try_from(generation.varint(3)?.unwrap_or(0)).map_err(|_| Malformed)?
                }
                None => 0,
            },
            created: timestamp(&message, 1)?,
            completed: timestamp(&message, 7)?,
            usage,
        })
    })();
    step.ok()
}

/// A token counter: absent means 0; a value that does not fit a signed 64-bit integer is
/// malformed.
fn token_count(message: &Message, number: u32) -> Result<i64, Malformed> {
    i64::try_from(message.varint(number)?.unwrap_or(0)).map_err(|_| Malformed)
}

/// A timestamp message (seconds in field 1, nanoseconds in field 2); absent when the message is.
fn timestamp(message: &Message, number: u32) -> Result<Option<DateTime<Utc>>, Malformed> {
    let Some(stamp) = message.message(number)? else {
        return Ok(None);
    };
    let seconds = stamp.varint(1)?.unwrap_or(0) as i64;
    let nanos = u32::try_from(stamp.varint(2)?.unwrap_or(0)).map_err(|_| Malformed)?;
    if nanos >= 1_000_000_000 {
        return Err(Malformed);
    }
    DateTime::from_timestamp(seconds, nanos)
        .map(Some)
        .ok_or(Malformed)
}

fn decode_executor(blob: &[u8]) -> Option<Executor> {
    let message = Message::parse(blob)?;
    let executor = (|| -> Result<Option<Executor>, Malformed> {
        let Some(id) = message.string(9)? else {
            return Ok(None);
        };
        let variant = match message.message(10)? {
            Some(selection) => match selection.message(1)? {
                Some(variant) => variant.string(28)?.map(str::to_owned),
                None => None,
            },
            None => None,
        };
        Ok(Some(Executor {
            id: id.to_owned(),
            state: message.varint(1)?.unwrap_or(0),
            variant,
        }))
    })();
    executor.ok().flatten()
}

fn decode_generation(blob: &[u8]) -> Option<Generation> {
    let message = Message::parse(blob)?;
    let generation = (|| -> Result<Generation, Malformed> {
        let Some(inner) = message.message(1)? else {
            return Ok(Generation {
                model: None,
                gemini_only: false,
            });
        };
        let model = inner.string(19)?.map(str::to_owned);
        let mut flags = Vec::new();
        for pair in inner.messages(20)? {
            if pair.string(1)? == Some("used_non_gemini_model") {
                flags.push(pair.string(2)? == Some("false"));
            }
        }
        Ok(Generation {
            model,
            gemini_only: !flags.is_empty() && flags.iter().all(|flag| *flag),
        })
    })();
    generation.ok()
}
