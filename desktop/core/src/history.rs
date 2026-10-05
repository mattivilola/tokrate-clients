use crate::model::TurnMetric;
use chrono::{DateTime, Duration, Utc};
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::fs;
use std::io::{self, ErrorKind, Write};
use std::path::Path;
use tempfile::NamedTempFile;

const SCHEMA_VERSION: u8 = 1;
const RETENTION_DAYS: i64 = 7;
const MAX_HISTORY_BYTES: u64 = 64 * 1024 * 1024;

#[derive(Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
struct PersistedHistory {
    schema_version: u8,
    records: Vec<TurnMetric>,
}

/// Deduplicated seven-day turn history, capped at 50,000 normalized metrics.
#[derive(Clone, Debug, Default)]
pub struct History {
    records: Vec<TurnMetric>,
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
        Ok(Self::from_records(persisted.records, now))
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
                by_id.insert(record.id.clone(), record.clone());
            }
        }
        self.records = by_id.into_values().collect();
        self.sort_and_cap();
    }

    pub fn save<P: AsRef<Path>>(&self, path: P) -> io::Result<()> {
        let path = path.as_ref();
        let parent = path
            .parent()
            .filter(|parent| !parent.as_os_str().is_empty())
            .unwrap_or_else(|| Path::new("."));
        fs::create_dir_all(parent)?;
        let data = serde_json::to_vec(&PersistedHistory {
            schema_version: SCHEMA_VERSION,
            records: self.records.clone(),
        })
        .map_err(|error| io::Error::new(ErrorKind::InvalidData, error))?;
        if data.len() as u64 > MAX_HISTORY_BYTES {
            return Err(io::Error::new(
                ErrorKind::InvalidData,
                "local history exceeds the size limit",
            ));
        }
        let mut temporary = NamedTempFile::new_in(parent)?;
        temporary.write_all(&data)?;
        temporary.as_file().sync_all()?;
        temporary.persist(path).map_err(|error| error.error)?;
        Ok(())
    }

    pub fn records(&self) -> &[TurnMetric] {
        &self.records
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
                by_id.insert(record.id.clone(), record);
            }
        }
        let mut history = Self {
            records: by_id.into_values().collect(),
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
