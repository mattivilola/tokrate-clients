use crate::delegation::DelegationTracker;
use crate::{GrokMonitor, Monitor, ResponseMetric, TurnMetric};
use chrono::{DateTime, Utc};
use std::collections::HashMap;
use std::io;
use std::path::PathBuf;

const TOTAL_POLL_BUDGET: usize = 1_048_576;
const CODEX_BUDGET: usize = 360_448;
const CLAUDE_TOTAL_BUDGET: usize = 360_448;
// Subagent transcripts get a reserved quarter of Claude's share so primary sessions and
// subagents each keep service while the other is catching up.
const CLAUDE_SUBAGENT_BUDGET: usize = CLAUDE_TOTAL_BUDGET / 4;
const CLAUDE_BUDGET: usize = CLAUDE_TOTAL_BUDGET - CLAUDE_SUBAGENT_BUDGET;
const GROK_BUDGET: usize = TOTAL_POLL_BUDGET - CODEX_BUDGET - CLAUDE_TOTAL_BUDGET;

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

        if self.codex_root.is_dir() {
            match self.codex.poll_with_budget(now, CODEX_BUDGET) {
                Ok(found) => records.extend(found),
                Err(error) if error.kind() == io::ErrorKind::NotFound => {}
                Err(_) => self.had_source_error = true,
            }
            self.bytes_read_last_poll += self.codex.bytes_read_last_poll();
        }
        if self.claude_root.is_dir() {
            let mut claude_records = Vec::new();
            match self.claude.poll_with_budget(now, CLAUDE_BUDGET) {
                Ok(found) => claude_records.extend(found),
                Err(error) if error.kind() == io::ErrorKind::NotFound => {}
                Err(_) => self.had_source_error = true,
            }
            self.bytes_read_last_poll += self.claude.bytes_read_last_poll();
            match self
                .claude_subagents
                .poll_with_budget(now, CLAUDE_SUBAGENT_BUDGET)
            {
                Ok(found) => claude_records.extend(found),
                Err(error) if error.kind() == io::ErrorKind::NotFound => {}
                Err(_) => self.had_source_error = true,
            }
            self.bytes_read_last_poll += self.claude_subagents.bytes_read_last_poll();
            let mut events = self.claude.take_delegation_events();
            events.extend(self.claude_subagents.take_delegation_events());
            records.extend(self.claude_delegation.apply(
                claude_records,
                events,
                now,
                self.claude_subagents.has_delegation_backlog(),
            ));
        }
        if self.grok_root.is_dir() {
            match self.grok.poll_with_budget(now, GROK_BUDGET) {
                Ok(found) => records.extend(found),
                Err(error) if error.kind() == io::ErrorKind::NotFound => {}
                Err(_) => self.had_source_error = true,
            }
            self.bytes_read_last_poll += self.grok.bytes_read_last_poll();
        }
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

    pub fn had_source_error(&self) -> bool {
        self.had_source_error
    }
}
