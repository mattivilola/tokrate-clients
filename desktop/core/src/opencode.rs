//! Monitor for OpenCode (sst/opencode: the TUI, `opencode run`, its desktop app and IDE
//! integrations), which keeps all sessions in one SQLite database under its data folder.

use crate::model::{push_outcomes, RequestOutcome, ResponseMetric, TurnMetric};
use crate::monitor::SourceChange;
use crate::opencode_db::{read_database, MessageScope};
use crate::opencode_turns::{live_response, request_outcome, Index, DELEGATION_MAX_WAIT_MS};
use crate::sqlite_read::{retry_delay, DatabaseSignature, Remembered};
use chrono::{DateTime, Duration, Utc};
use std::collections::HashMap;
use std::io;
use std::path::{Path, PathBuf};

const DATABASE_FILE: &str = "opencode.db";
/// The history retention: older messages and an untouched database are not read.
const RETENTION_DAYS: i64 = 7;
/// Later reads take messages updated this long before the newest one seen (milliseconds).
const WATERMARK_OVERLAP_MS: i64 = 2_000;
/// A full re-read rebuilds the index this often while the database keeps changing, so messages
/// OpenCode deleted (a revert) leave it.
const FULL_READ_MINUTES: i64 = 5;

/// A turn that was emitted: whether its delegated output was final, and when it ended.
struct Emitted {
    delegated_final: bool,
    session_id: String,
    completed_at: DateTime<Utc>,
}

impl Emitted {
    /// When a turn with unfinished delegated work stops waiting for it.
    fn settles_at(&self) -> DateTime<Utc> {
        self.completed_at + Duration::milliseconds(DELEGATION_MAX_WAIT_MS)
    }
}

/// Bounded reader for OpenCode's database, with an in-memory index of the last seven days.
pub struct OpenCodeMonitor {
    root: PathBuf,
    index: Index,
    /// The signature the last successful read started from.
    read_at: Option<DatabaseSignature>,
    /// The files as last seen: refreshed by every poll and by a watcher report for the database.
    current: Option<DatabaseSignature>,
    last_full_read: Option<DateTime<Utc>>,
    failures: u32,
    retry_at: Option<DateTime<Utc>>,
    emitted: HashMap<String, Emitted>,
    published: Remembered<String>,
    /// The messages whose request outcome was reported already.
    outcomes_published: Remembered<String>,
    /// First poll time: only responses completed after it are published live.
    started_at: Option<DateTime<Utc>>,
    bytes_read_last_poll: usize,
    live_responses: Vec<ResponseMetric>,
    request_outcomes: Vec<RequestOutcome>,
}

impl OpenCodeMonitor {
    pub const MAX_POLL_BYTES: usize = 1_048_576;

    pub fn new(root: PathBuf) -> Self {
        Self {
            root,
            index: Index::default(),
            read_at: None,
            current: None,
            last_full_read: None,
            failures: 0,
            retry_at: None,
            emitted: HashMap::new(),
            published: Remembered::new(),
            outcomes_published: Remembered::new(),
            started_at: None,
            bytes_read_last_poll: 0,
            live_responses: Vec::new(),
            request_outcomes: Vec::new(),
        }
    }

    /// `<root>/opencode.db`: the only file read; the older JSON `storage/` folder is ignored.
    pub fn database_path(root: &Path) -> PathBuf {
        root.join(DATABASE_FILE)
    }

    /// Whether OpenCode's database exists under a data root.
    pub fn has_database(root: &Path) -> bool {
        Self::database_path(root).is_file()
    }

    pub fn poll(&mut self, now: DateTime<Utc>) -> io::Result<Vec<TurnMetric>> {
        self.poll_with_budget(now, Self::MAX_POLL_BYTES)
    }

    /// Reads what changed since the last poll and returns the turns that became complete, and the
    /// turns whose delegated output became final since they were first returned (same id).
    pub fn poll_with_budget(
        &mut self,
        now: DateTime<Utc>,
        max_bytes: usize,
    ) -> io::Result<Vec<TurnMetric>> {
        self.bytes_read_last_poll = 0;
        let started_at = *self.started_at.get_or_insert(now);
        let path = Self::database_path(&self.root);
        let cutoff = now - Duration::days(RETENTION_DAYS);
        let mut dirty: std::collections::HashSet<String> = std::collections::HashSet::new();

        self.current = DatabaseSignature::of(&path);
        let signature = self.current;
        let changed = signature.is_some_and(|signature| {
            signature
                .modified()
                .is_some_and(|modified| modified >= cutoff)
                && self.read_at != Some(signature)
                && self.retry_at.is_none_or(|retry_at| retry_at <= now)
        });
        if let (true, Some(signature), true) = (changed, signature, max_bytes > 0) {
            // A database that got smaller was replaced or compacted: its messages are not an
            // extension of what the index holds.
            let full = self
                .read_at
                .is_none_or(|read| signature.database_len() < read.database_len())
                || self.last_full_read.is_none_or(|last| {
                    now < last || now - last >= Duration::minutes(FULL_READ_MINUTES)
                });
            let cutoff_ms = cutoff.timestamp_millis();
            let scope = if full {
                MessageScope::CreatedSince(cutoff_ms)
            } else {
                MessageScope::UpdatedSince {
                    updated: self.index.watermark - WATERMARK_OVERLAP_MS,
                    created_since: cutoff_ms,
                }
            };
            let index = &self.index;
            match read_database(&path, scope, full, &|id| !full && index.has_session(id)) {
                // An unreadable database (locked, corrupt, another schema) is retried with a
                // growing delay; the index keeps what it had.
                Err(_) => {
                    self.failures = self.failures.saturating_add(1);
                    self.retry_at = Some(now + retry_delay(self.failures));
                }
                Ok(read) => {
                    self.failures = 0;
                    self.retry_at = None;
                    self.read_at = Some(signature);
                    self.bytes_read_last_poll = read.bytes_read;
                    if full {
                        self.index.clear();
                        self.last_full_read = Some(now);
                    }
                    let merged = self.index.merge(read, cutoff_ms);
                    self.index.prune(cutoff_ms);
                    dirty = merged.dirty_sessions;
                    if full {
                        dirty.extend(self.index.primary_sessions());
                    }
                    for (session_id, message_id) in merged.assistants {
                        // Memory only, and only what finished after this monitor started: the
                        // history the database holds is not a request made while sharing was on.
                        if !self.outcomes_published.contains(&message_id) {
                            let outcome = self
                                .index
                                .measured_assistant(&session_id, &message_id)
                                .and_then(|(version, assistant)| {
                                    request_outcome(&message_id, version, assistant, started_at)
                                });
                            if let Some(outcome) = outcome {
                                self.outcomes_published.insert(message_id.clone());
                                push_outcomes(&mut self.request_outcomes, vec![outcome]);
                            }
                        }
                        let Some(assistant) =
                            self.index.primary_assistant(&session_id, &message_id)
                        else {
                            continue;
                        };
                        if self.published.contains(&message_id) {
                            continue;
                        }
                        if let Some(response) = live_response(&message_id, assistant, started_at) {
                            self.published.insert(message_id);
                            self.live_responses.push(response);
                        }
                    }
                }
            }
        }
        self.emitted
            .retain(|_, emitted| emitted.completed_at >= cutoff);

        // A turn still waiting for its delegated output is evaluated again when its wait runs out:
        // that ends with time, not with a database change (a change reaches it as a dirty session).
        dirty.extend(
            self.emitted
                .values()
                .filter(|emitted| !emitted.delegated_final && emitted.settles_at() <= now)
                .map(|emitted| emitted.session_id.clone()),
        );
        let mut records = Vec::new();
        for session_id in dirty {
            for turn in self.index.evaluate(&session_id, now) {
                let id = turn.metric.id.clone();
                match self.emitted.get_mut(&id) {
                    // Already final, or still waiting: nothing new to say.
                    Some(emitted) if emitted.delegated_final || !turn.delegated_final => continue,
                    Some(emitted) => emitted.delegated_final = true,
                    None => {
                        self.emitted.insert(
                            id,
                            Emitted {
                                delegated_final: turn.delegated_final,
                                session_id: session_id.clone(),
                                completed_at: turn.metric.completed_at,
                            },
                        );
                    }
                }
                records.push(turn.metric);
            }
        }
        records.sort_by(|left, right| {
            right
                .completed_at
                .cmp(&left.completed_at)
                .then_with(|| left.id.cmp(&right.id))
        });
        Ok(records)
    }

    pub fn bytes_read_last_poll(&self) -> usize {
        self.bytes_read_last_poll
    }

    /// Whether the data folder exists now.
    pub fn root_exists(&self) -> bool {
        self.root.is_dir()
    }

    /// Marks what a folder watcher reported so the next poll reads it. Only `opencode.db` and
    /// `opencode.db-wal` directly in the data folder matter; the folder also holds snapshots, tool
    /// output and logs that change constantly and must not wake a poll. Paths must be spelled
    /// under the root as the monitor was created with. Returns whether a poll has work now.
    pub fn note_changes(&mut self, change: &SourceChange) -> bool {
        let database = Self::database_path(&self.root);
        let log = crate::sqlite_read::wal_path(&database);
        if !change.must_rescan
            && !change
                .paths
                .iter()
                .any(|path| *path == database || *path == log)
        {
            return false;
        }
        self.current = DatabaseSignature::of(&database);
        // A lost event is answered by a poll, which looks at the files itself.
        change.must_rescan
            || self
                .current
                .is_some_and(|current| self.read_at != Some(current))
    }

    /// When the monitor must poll again if nothing else changes: `now` while a changed database
    /// waits to be read, the retry time after a failed read, else the earliest moment a turn stops
    /// waiting for unfinished subagent messages; `None` when nothing is pending.
    pub fn next_poll_deadline(&self, now: DateTime<Utc>) -> Option<DateTime<Utc>> {
        let waiting = self
            .emitted
            .values()
            .filter(|emitted| !emitted.delegated_final);
        let settle = waiting.map(Emitted::settles_at).min();
        let cutoff = now - Duration::days(RETENTION_DAYS);
        let read = self
            .current
            .filter(|current| {
                self.read_at != Some(*current)
                    && current
                        .modified()
                        .is_some_and(|modified| modified >= cutoff)
            })
            .map(|_| self.retry_at.map_or(now, |retry| retry.max(now)));
        [settle, read].into_iter().flatten().min()
    }

    /// Request outcomes of the assistant messages that finished since the last call. Memory only.
    pub fn take_request_outcomes(&mut self) -> Vec<RequestOutcome> {
        std::mem::take(&mut self.request_outcomes)
    }

    /// Qualifying assistant messages completed since the last call, oldest first.
    pub fn take_live_responses(&mut self) -> Vec<ResponseMetric> {
        let mut responses = std::mem::take(&mut self.live_responses);
        responses.sort_by(|left, right| {
            left.completed_at
                .cmp(&right.completed_at)
                .then_with(|| left.id.cmp(&right.id))
        });
        responses
    }
}
