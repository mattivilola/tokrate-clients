//! Read-only access to an Antigravity conversation database.
//!
//! Antigravity keeps one SQLite database per conversation. Its layout is not a public API, so
//! every failure here (locked, corrupt, schema mismatch, undecodable blob) is reported as
//! unreadable and the caller skips the database until its next change. Only the columns the
//! metrics contract allows are selected, and only numeric usage, timestamps, model ids, the
//! effort suffix and execution ids are decoded from them.

use crate::protobuf::{Malformed, Message};
use crate::sqlite_read::open_read_only;
use chrono::{DateTime, Utc};
use rusqlite::types::Value;
use std::collections::HashMap;
use std::path::Path;

const MAX_STEPS: usize = 100_000;
const MAX_EXECUTORS: usize = 10_000;
/// Decoded generations (and unreadable generation rows) remembered per database.
const MAX_CACHED_GENERATIONS: usize = 4_096;
/// A blob above this size is treated as unreadable instead of being loaded.
const MAX_BLOB_BYTES: i64 = 8 * 1_048_576;
/// A database whose blobs add up to more than this in one read is skipped like one with too many
/// rows: the row limits alone would allow gigabytes.
const MAX_SNAPSHOT_BYTES: usize = 256 * 1_048_576;
/// Longest execution id, variant or model decoded from a blob. A longer one makes the blob
/// unreadable instead of being kept in memory.
const MAX_DECODED_STRING_BYTES: usize = 512;

/// Why a database was skipped for this poll.
#[derive(Debug)]
pub(crate) enum ReadError {
    Sqlite,
    /// A table holds more rows than Tokrate is willing to hold in memory.
    TooLarge,
    /// A step's metadata is not a readable message, so the steps cannot be attributed safely.
    Undecodable,
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
    /// 9.2: uncached input tokens.
    pub input_tokens: i64,
    /// 9.5: input tokens read from the prompt cache.
    pub cache_read_tokens: i64,
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

/// Generations decoded so far for one database, by `gen_metadata.idx`. A generation row never
/// changes once written, so each is fetched and decoded once; one that exists but cannot be
/// decoded is remembered too and not fetched again.
#[derive(Default)]
pub(crate) struct GenerationCache {
    decoded: HashMap<i64, Generation>,
    unreadable: std::collections::HashSet<i64>,
}

impl GenerationCache {
    fn contains(&self, idx: i64) -> bool {
        self.decoded.contains_key(&idx) || self.unreadable.contains(&idx)
    }

    fn get(&self, idx: i64) -> Option<&Generation> {
        self.decoded.get(&idx)
    }

    fn remember(&mut self, idx: i64, generation: Generation) {
        if self.decoded.len() < MAX_CACHED_GENERATIONS {
            self.decoded.insert(idx, generation);
        }
    }

    fn remember_unreadable(&mut self, idx: i64) {
        if self.unreadable.len() < MAX_CACHED_GENERATIONS {
            self.unreadable.insert(idx);
        }
    }
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

/// The `has_subtrajectory` flag as read by [`truthy`], without materializing a value that could
/// not be true: only a number or short text can be.
const FLAG_COLUMN: &str = "CASE typeof(has_subtrajectory) \
    WHEN 'integer' THEN has_subtrajectory WHEN 'real' THEN has_subtrajectory \
    WHEN 'text' THEN CASE WHEN length(has_subtrajectory) <= 16 THEN has_subtrajectory END END";

/// Reads one database. Never writes: the connection is read-only, honours the write-ahead log
/// (no `immutable`) and waits at most half a second for a lock.
pub(crate) fn read_database(
    path: &Path,
    cache: &mut GenerationCache,
) -> Result<Snapshot, ReadError> {
    read_database_within(path, cache, MAX_SNAPSHOT_BYTES)
}

/// [`read_database`] with its own limit on the blob bytes one read may load.
pub(crate) fn read_database_within(
    path: &Path,
    cache: &mut GenerationCache,
    max_bytes: usize,
) -> Result<Snapshot, ReadError> {
    let mut connection = open_read_only(path)?;
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

    let mut statement = transaction.prepare(&format!(
        "SELECT idx, {FLAG_COLUMN}, \
         CASE WHEN length(metadata) <= ?1 THEN metadata END, length(metadata) \
         FROM steps ORDER BY idx LIMIT ?2",
    ))?;
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
        if snapshot.bytes_read > max_bytes {
            return Err(ReadError::TooLarge);
        }
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
        if snapshot.bytes_read > max_bytes {
            return Err(ReadError::TooLarge);
        }
        // An unreadable executor row leaves its execution unfinished as far as Tokrate knows.
        if let Some(executor) = decode_executor(&blob) {
            snapshot.executors.push(executor);
        }
    }
    drop(rows);
    drop(statement);

    // Only the generations the model calls reference, each fetched and decoded once: their rows
    // can be megabytes. A row that is absent is asked for again on the next read.
    let mut referenced: Vec<i64> = snapshot
        .steps
        .iter()
        .filter(|step| step.usage.is_some())
        .map(|step| step.generation)
        .collect();
    referenced.sort_unstable();
    referenced.dedup();
    let mut statement = transaction.prepare(
        "SELECT CASE WHEN length(data) <= ?1 THEN data END FROM gen_metadata WHERE idx = ?2",
    )?;
    for idx in referenced {
        if !cache.contains(idx) {
            let mut rows = statement.query(rusqlite::params![MAX_BLOB_BYTES, idx])?;
            // `None`: no row (yet). `Some(None)`: a row too large to load.
            let row = match rows.next()? {
                Some(row) => Some(row.get::<_, Option<Vec<u8>>>(0)?),
                None => None,
            };
            match row {
                None => {}
                Some(None) => cache.remember_unreadable(idx),
                Some(Some(blob)) => {
                    snapshot.bytes_read += blob.len();
                    if snapshot.bytes_read > max_bytes {
                        return Err(ReadError::TooLarge);
                    }
                    match decode_generation(&blob) {
                        Some(generation) => cache.remember(idx, generation),
                        // An unreadable generation leaves its model calls without a model.
                        None => cache.remember_unreadable(idx),
                    }
                }
            }
        }
        if let Some(generation) = cache.get(idx) {
            snapshot.generations.insert(idx, generation.clone());
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
                input_tokens: token_count(&usage, 2)?,
                cache_read_tokens: token_count(&usage, 5)?,
            }),
            None => None,
        };
        Ok(Step {
            idx,
            has_subtrajectory,
            execution_id: bounded(message.string(12)?)?,
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

/// A string read from a blob and kept, or `Malformed` when it is longer than
/// [`MAX_DECODED_STRING_BYTES`].
fn bounded(value: Option<&str>) -> Result<Option<String>, Malformed> {
    match value {
        Some(value) if value.len() > MAX_DECODED_STRING_BYTES => Err(Malformed),
        other => Ok(other.map(str::to_owned)),
    }
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
        let Some(id) = bounded(message.string(9)?)? else {
            return Ok(None);
        };
        let variant = match message.message(10)? {
            Some(selection) => match selection.message(1)? {
                Some(variant) => bounded(variant.string(28)?)?,
                None => None,
            },
            None => None,
        };
        Ok(Some(Executor {
            id,
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
        let model = bounded(inner.string(19)?)?;
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
