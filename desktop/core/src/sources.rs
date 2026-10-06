use crate::delegation::DelegationTracker;
use crate::monitor::{SourceChange, SourceFileCheckpoint, MAX_FILES};
use crate::{GrokMonitor, Monitor, ResponseMetric, TurnMetric};
use chrono::{DateTime, Duration, Utc};
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::io;
use std::path::{Path, PathBuf};

/// Local history keeps what it needs for seven days; so do checkpoints.
const CHECKPOINT_RETENTION_DAYS: i64 = 7;

const TOTAL_POLL_BUDGET: usize = 1_048_576;
const CODEX_BUDGET: usize = 360_448;
const CLAUDE_TOTAL_BUDGET: usize = 360_448;
// Subagent transcripts get a reserved quarter of Claude's share so primary sessions and
// subagents each keep service while the other is catching up.
const CLAUDE_SUBAGENT_BUDGET: usize = CLAUDE_TOTAL_BUDGET / 4;
const CLAUDE_BUDGET: usize = CLAUDE_TOTAL_BUDGET - CLAUDE_SUBAGENT_BUDGET;
const GROK_BUDGET: usize = TOTAL_POLL_BUDGET - CODEX_BUDGET - CLAUDE_TOTAL_BUDGET;

/// The launch checkpoints of every file monitor, saved with the local history. Grok Build reads
/// whole session folders, which are cheap to rescan, so it has none.
#[derive(Clone, Debug, Default, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SourceCheckpoints {
    #[serde(default)]
    pub codex: Vec<SourceFileCheckpoint>,
    #[serde(default)]
    pub claude_primary: Vec<SourceFileCheckpoint>,
    #[serde(default)]
    pub claude_subagents: Vec<SourceFileCheckpoint>,
}

impl SourceCheckpoints {
    pub fn is_empty(&self) -> bool {
        self.codex.is_empty() && self.claude_primary.is_empty() && self.claude_subagents.is_empty()
    }

    /// Without entries older than the retention, and at most the monitors' file cap per source,
    /// newest first.
    pub fn retained(mut self, now: DateTime<Utc>) -> Self {
        let cutoff = now - Duration::days(CHECKPOINT_RETENTION_DAYS);
        for list in [
            &mut self.codex,
            &mut self.claude_primary,
            &mut self.claude_subagents,
        ] {
            list.retain(|checkpoint| checkpoint.modified_at >= cutoff);
            list.sort_by(|left, right| {
                right
                    .modified_at
                    .cmp(&left.modified_at)
                    .then_with(|| left.path_digest.cmp(&right.path_digest))
            });
            list.truncate(MAX_FILES);
        }
        self
    }
}

/// Polls the three supported local data roots under one aggregate content-read limit.
pub struct SourceMonitor {
    codex_root: PathBuf,
    claude_root: PathBuf,
    grok_root: PathBuf,
    codex: Monitor,
    claude: Monitor,
    claude_subagents: Monitor,
    /// Joins Claude's primary and subagent monitors: subagent work belongs to the primary turn
    /// of the same session that started it.
    claude_delegation: DelegationTracker,
    grok: GrokMonitor,
    bytes_read_last_poll: usize,
    had_source_error: bool,
}

impl SourceMonitor {
    pub const MAX_POLL_BYTES: usize = TOTAL_POLL_BUDGET;

    pub fn new(codex_root: PathBuf, claude_root: PathBuf, grok_root: PathBuf) -> Self {
        Self {
            codex: Monitor::new(codex_root.clone()),
            claude: Monitor::new_claude(claude_root.clone()),
            claude_subagents: Monitor::new_claude_subagents(claude_root.clone()),
            claude_delegation: DelegationTracker::new(),
            grok: GrokMonitor::new(grok_root.clone()),
            codex_root,
            claude_root,
            grok_root,
            bytes_read_last_poll: 0,
            had_source_error: false,
        }
    }

    pub fn set_root(&mut self, source: &str, root: PathBuf) -> io::Result<()> {
        match source {
            "codex" => {
                self.codex_root = root.clone();
                self.codex = Monitor::new(root);
            }
            "claude-code" => {
                self.claude_root = root.clone();
                self.claude_subagents = Monitor::new_claude_subagents(root.clone());
                self.claude = Monitor::new_claude(root);
                self.claude_delegation = DelegationTracker::new();
            }
            "grok-build" => {
                self.grok_root = root.clone();
                self.grok = GrokMonitor::new(root);
            }
            _ => {
                return Err(io::Error::new(
                    io::ErrorKind::InvalidInput,
                    "unknown source",
                ))
            }
        }
        Ok(())
    }

    pub fn root(&self, source: &str) -> Option<&PathBuf> {
        match source {
            "codex" => Some(&self.codex_root),
            "claude-code" => Some(&self.claude_root),
            "grok-build" => Some(&self.grok_root),
            _ => None,
        }
    }

    pub fn poll(&mut self, now: DateTime<Utc>) -> io::Result<Vec<TurnMetric>> {
        self.bytes_read_last_poll = 0;
        let mut records = Vec::new();
        self.had_source_error = false;

        // Each monitor notices a root that is missing or has just appeared; a missing one costs a
        // stat per poll.
        match self.codex.poll_with_budget(now, CODEX_BUDGET) {
            Ok(found) => records.extend(found),
            Err(error) if error.kind() == io::ErrorKind::NotFound => {}
            Err(_) => self.had_source_error = true,
        }
        self.bytes_read_last_poll += self.codex.bytes_read_last_poll();
        let mut claude_records = Vec::new();
        match self.claude.poll_with_budget(now, CLAUDE_BUDGET) {
            Ok(found) => claude_records.extend(found),
            Err(error) if error.kind() == io::ErrorKind::NotFound => {}
            Err(_) => self.had_source_error = true,
        }
        self.bytes_read_last_poll += self.claude.bytes_read_last_poll();
        // Without a subagent view no turn can tell whether its work was seen.
        let mut subagents_unreadable = false;
        match self
            .claude_subagents
            .poll_with_budget(now, CLAUDE_SUBAGENT_BUDGET)
        {
            Ok(found) => claude_records.extend(found),
            Err(error) if error.kind() == io::ErrorKind::NotFound => {}
            Err(_) => {
                self.had_source_error = true;
                subagents_unreadable = true;
            }
        }
        self.bytes_read_last_poll += self.claude_subagents.bytes_read_last_poll();
        let mut events = self.claude.take_delegation_events();
        events.extend(self.claude_subagents.take_delegation_events());
        let subagents = &self.claude_subagents;
        records.extend(self.claude_delegation.apply(
            claude_records,
            events,
            now,
            |work_start| subagents_unreadable || subagents.has_delegation_backlog_since(work_start),
            |work_start| subagents.has_skipped_delegation_work_since(work_start),
        ));
        match self.grok.poll_with_budget(now, GROK_BUDGET) {
            Ok(found) => records.extend(found),
            Err(error) if error.kind() == io::ErrorKind::NotFound => {}
            Err(_) => self.had_source_error = true,
        }
        self.bytes_read_last_poll += self.grok.bytes_read_last_poll();
        if self.bytes_read_last_poll > TOTAL_POLL_BUDGET {
            return Err(io::Error::other("source monitor exceeded its read budget"));
        }
        let mut unique = HashMap::new();
        for record in records {
            unique.insert(record.id.clone(), record);
        }
        let mut records: Vec<TurnMetric> = unique.into_values().collect();
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

    /// Live responses completed since the last call, oldest first (Grok has no per-response
    /// timing and contributes none).
    pub fn take_live_responses(&mut self) -> Vec<ResponseMetric> {
        let mut responses = self.codex.take_live_responses();
        responses.extend(self.claude.take_live_responses());
        responses.extend(self.claude_subagents.take_live_responses());
        responses.sort_by(|left, right| {
            left.completed_at
                .cmp(&right.completed_at)
                .then_with(|| left.id.cmp(&right.id))
        });
        responses
    }

    /// Reports what a folder watcher saw, to the monitors whose root holds the changed paths. A
    /// request to rescan has no path and goes to every monitor. Returns whether anything is now
    /// pending, so the host can wake the next poll.
    pub fn note_changes(&mut self, change: &SourceChange) -> bool {
        let within = |root: &Path| SourceChange {
            paths: change
                .paths
                .iter()
                .filter(|path| path.starts_with(root))
                .cloned()
                .collect(),
            must_rescan: change.must_rescan,
        };
        let codex = within(&self.codex_root);
        let claude = within(&self.claude_root);
        let grok = within(&self.grok_root);
        let noted_codex = self.codex.note_changes(&codex);
        let noted_primary = self.claude.note_changes(&claude);
        let noted_subagents = self.claude_subagents.note_changes(&claude);
        let noted_grok = self.grok.note_changes(&grok);
        noted_codex || noted_primary || noted_subagents || noted_grok
    }

    /// When the host must poll again if nothing else changes: `now` while any source has data
    /// left to read or discovery waiting, else the earliest delegation settle or parser flush,
    /// else `None` (only a watcher note or the host's idle cadence needs to wake the poll).
    pub fn next_poll_deadline(&self, now: DateTime<Utc>) -> Option<DateTime<Utc>> {
        [
            self.codex.next_poll_deadline(now),
            self.claude.next_poll_deadline(now),
            self.claude_subagents.next_poll_deadline(now),
            self.claude_delegation.next_deadline(now),
            self.grok.next_poll_deadline(now),
        ]
        .into_iter()
        .flatten()
        .min()
    }

    /// Whether a source's root folder exists now, so a host whose watcher could not start can
    /// retry once it does. `None` for an unknown source.
    pub fn root_exists(&self, source: &str) -> Option<bool> {
        match source {
            "codex" => Some(self.codex.root_exists()),
            "claude-code" => Some(self.claude.root_exists()),
            "grok-build" => Some(self.grok.root_exists()),
            _ => None,
        }
    }

    /// Hands the monitors the checkpoints a previous run saved. Call before the first poll.
    pub fn set_checkpoints(&mut self, checkpoints: SourceCheckpoints) {
        self.codex.set_checkpoints(checkpoints.codex);
        self.claude.set_checkpoints(checkpoints.claude_primary);
        self.claude_subagents
            .set_checkpoints(checkpoints.claude_subagents);
    }

    /// The checkpoints to save now. A source that cannot give a consistent set right now (nothing
    /// enumerated yet, or a primary turn still waiting for its delegated output) keeps its entry
    /// of `previous`. Claude's two monitors share one delegation state, which this owner holds.
    pub fn checkpoints(&self, previous: &SourceCheckpoints) -> SourceCheckpoints {
        let claude_pending = self.claude_delegation.has_pending();
        let claude = |monitor: &Monitor, previous: &Vec<SourceFileCheckpoint>| {
            monitor
                .checkpoints()
                .filter(|_| !claude_pending)
                .unwrap_or_else(|| previous.clone())
        };
        SourceCheckpoints {
            codex: self
                .codex
                .checkpoints()
                .unwrap_or_else(|| previous.codex.clone()),
            claude_primary: claude(&self.claude, &previous.claude_primary),
            claude_subagents: claude(&self.claude_subagents, &previous.claude_subagents),
        }
    }

    pub fn had_source_error(&self) -> bool {
        self.had_source_error
    }
}
