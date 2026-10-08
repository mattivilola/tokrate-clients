use crate::model::TurnMetric;
use crate::private_file::write_private_file;
use crate::sources::SourceCheckpoints;
use chrono::{DateTime, Duration, Utc};
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::fs;
use std::io::{self, ErrorKind};
use std::path::Path;

const SCHEMA_VERSION: u8 = 1;
const RETENTION_DAYS: i64 = 7;
const MAX_HISTORY_BYTES: u64 = 64 * 1024 * 1024;

#[derive(Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
struct PersistedHistory {
    schema_version: u8,
    records: Vec<TurnMetric>,
    /// Where the monitors finished reading, saved with the records they produced so a launch can
    /// skip those files. Absent in files from before checkpoints; an older app ignores it.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    checkpoints: Option<SourceCheckpoints>,
}

/// Deduplicated seven-day turn history, capped at 50,000 normalized metrics, and the launch
/// checkpoints that belong to it.
#[derive(Clone, Debug, Default)]
pub struct History {
    records: Vec<TurnMetric>,
    checkpoints: SourceCheckpoints,
}

impl History {
    pub const MAX_RECORDS: usize = 50_000;

    pub fn load<P: AsRef<Path>>(path: P, now: DateTime<Utc>) -> io::Result<Self> {
        let path = path.as_ref();
        let metadata = match fs::metadata(path) {
            Ok(metadata) => metadata,
            Err(error) if error.kind() == ErrorKind::NotFound => return Ok(Self::default()),
            Err(error) => return Err(error),
        };
        if metadata.len() > MAX_HISTORY_BYTES {
            return Err(io::Error::new(
                ErrorKind::InvalidData,
                "local history exceeds the size limit",
            ));
        }
        let data = fs::read(path)?;
        let persisted: PersistedHistory = serde_json::from_slice(&data)
            .map_err(|error| io::Error::new(ErrorKind::InvalidData, error))?;
        if persisted.schema_version != SCHEMA_VERSION {
            return Err(io::Error::new(
                ErrorKind::InvalidData,
                "unsupported local history schema",
            ));
        }
        let mut history = Self::from_records(persisted.records, now);
        history.checkpoints = persisted.checkpoints.unwrap_or_default().retained(now);
        Ok(history)
    }

    pub fn merge(&mut self, records: &[TurnMetric], now: DateTime<Utc>) {
        self.prune(now);
        let cutoff = now - Duration::days(RETENTION_DAYS);
        let mut by_id: HashMap<String, TurnMetric> = self
            .records
            .drain(..)
            .map(|record| (record.id.clone(), record))
            .collect();
        for record in records {
            if record.completed_at >= cutoff && record.completed_at <= now {
                let mut record = record.clone();
                // A record whose delegated output is not final (a replay, before its total
                // settles) must not erase a total that is: it is the same turn.
                if record.delegated_output_tokens.is_none() {
                    record.delegated_output_tokens = by_id
                        .get(&record.id)
                        .and_then(|known| known.delegated_output_tokens);
                }
                by_id.insert(record.id.clone(), record);
            }
        }
        self.records = by_id.into_values().collect();
        self.sort_and_cap();
    }

    pub fn save<P: AsRef<Path>>(&self, path: P) -> io::Result<()> {
        let data = serde_json::to_vec(&PersistedHistory {
            schema_version: SCHEMA_VERSION,
            records: self.records.clone(),
            checkpoints: (!self.checkpoints.is_empty()).then(|| self.checkpoints.clone()),
        })
        .map_err(|error| io::Error::new(ErrorKind::InvalidData, error))?;
        if data.len() as u64 > MAX_HISTORY_BYTES {
            return Err(io::Error::new(
                ErrorKind::InvalidData,
                "local history exceeds the size limit",
            ));
        }
        write_private_file(path, &data)
    }

    pub fn records(&self) -> &[TurnMetric] {
        &self.records
    }

    /// The saved launch checkpoints: pass them to the monitors before their first poll.
    pub fn checkpoints(&self) -> &SourceCheckpoints {
        &self.checkpoints
    }

    /// Replaces the checkpoints to be saved with the next [`History::save`], so they reach the
    /// disk together with the records the monitors produced up to them. Entries older than the
    /// retention are dropped, and each source keeps at most the monitors' file cap.
    pub fn set_checkpoints(&mut self, checkpoints: SourceCheckpoints, now: DateTime<Utc>) {
        self.checkpoints = checkpoints.retained(now);
    }

    fn from_records(records: Vec<TurnMetric>, now: DateTime<Utc>) -> Self {
        let cutoff = now - Duration::days(RETENTION_DAYS);
        let mut by_id = HashMap::new();
        for mut record in records {
            // Saved by an earlier version: drop impossible speeds and unusable response timing.
            if record.completed_at >= cutoff
                && record.completed_at <= now
                && record.turn_speed_is_plausible()
            {
                if record.plausible_response_timing().is_none() {
                    record.response_output_tokens = None;
                    record.response_duration_seconds = None;
                    record.response_count = None;
                }
                // A stored set that is not consistent reads as not reported.
                record.set_prompt_cache(
                    record.input_tokens,
                    record.cache_read_input_tokens,
                    record.cache_write_input_tokens,
                );
                by_id.insert(record.id.clone(), record);
            }
        }
        let mut history = Self {
            records: by_id.into_values().collect(),
            checkpoints: SourceCheckpoints::default(),
        };
        history.sort_and_cap();
        history
    }

    fn prune(&mut self, now: DateTime<Utc>) {
        let cutoff = now - Duration::days(RETENTION_DAYS);
        self.records
            .retain(|record| record.completed_at >= cutoff && record.completed_at <= now);
    }

    fn sort_and_cap(&mut self) {
        self.records.sort_by(|left, right| {
            right
                .completed_at
                .cmp(&left.completed_at)
                .then_with(|| left.id.cmp(&right.id))
        });
        self.records.truncate(Self::MAX_RECORDS);
    }
}
