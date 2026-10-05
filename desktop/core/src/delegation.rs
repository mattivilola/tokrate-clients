//! In-memory attribution of delegated subagent output to the primary turn that started it.
//!
//! Parsers report work lifecycle events through a side channel; a monitor that owns both the
//! primary and the delegated source feeds them, with the primary records it polled, to a
//! [`DelegationTracker`]. Root-session keys are digests kept only in memory: they are never
//! persisted, shared or logged.

use crate::model::TurnMetric;
use chrono::{DateTime, Duration, Utc};
use sha2::{Digest, Sha256};
use std::collections::{HashMap, HashSet};

/// A primary turn waits this long after it ended before its delegated output is settled.
pub(crate) const DELEGATION_SETTLE_SECONDS: i64 = 30;
/// Work still open this long after the turn ended (a background agent) is not counted.
pub(crate) const DELEGATION_MAX_WAIT_SECONDS: i64 = 1_800;
/// Matches the local history retention: older work can never belong to a retained turn.
const RETENTION_DAYS: i64 = 7;
const MAX_WORK_ITEMS: usize = 20_000;
const MAX_PENDING_TURNS: usize = 10_000;
/// Events wait here until a monitor drains them after each poll.
pub(crate) const MAX_BUFFERED_EVENTS: usize = 16_384;

/// Digest of `client|rawRootSessionId`: the in-memory join key between primary turns and work.
pub(crate) fn root_session_key(client: &str, raw_root_session_id: &str) -> String {
    format!(
        "{:x}",
        Sha256::digest(format!("{client}|{raw_root_session_id}").as_bytes())
    )
}

/// What a parser tells the attribution about turns and delegated work it has read.
#[derive(Clone, Debug, PartialEq)]
pub(crate) enum DelegationEvent {
    /// A primary turn was emitted as `turn_id` (its [`TurnMetric::id`]).
    Turn {
        turn_id: String,
        root_session: String,
        started_at: DateTime<Utc>,
    },
    /// A delegated work item (one subagent or child-session turn) started.
    Started {
        work_id: String,
        root_session: String,
        started_at: DateTime<Utc>,
    },
    Finished {
        work_id: String,
        output_tokens: i64,
        finished_at: DateTime<Utc>,
    },
    /// Interrupted, aborted, stale or otherwise unmeasurable work.
    Discarded { work_id: String },
}

/// Appends events to a buffer that keeps only the newest [`MAX_BUFFERED_EVENTS`].
pub(crate) fn extend_bounded(buffer: &mut Vec<DelegationEvent>, events: Vec<DelegationEvent>) {
    buffer.extend(events);
    let excess = buffer.len().saturating_sub(MAX_BUFFERED_EVENTS);
    buffer.drain(..excess);
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum WorkState {
    Open,
    Finished(i64),
    Discarded,
}

struct WorkItem {
    root_session: String,
    started_at: DateTime<Utc>,
    state: WorkState,
}

struct PendingTurn {
    root_session: String,
    started_at: DateTime<Utc>,
    completed_at: DateTime<Utc>,
    metric: TurnMetric,
}

/// Work ledger plus the primary turns still waiting for their delegated output.
#[derive(Default)]
pub(crate) struct DelegationTracker {
    items: HashMap<String, WorkItem>,
    by_root: HashMap<String, HashSet<String>>,
    pending: HashMap<String, PendingTurn>,
}

impl DelegationTracker {
    pub fn new() -> Self {
        Self::default()
    }

    /// Takes one poll's primary records and events. Records pass through unchanged, so speeds
    /// update at once; each primary turn with a known root session also becomes pending. Turns
    /// that are final are returned with their delegated output set, replacing the pending
    /// version of the same id.
    ///
    /// `backlog` is true while the delegated source still has history to read: nothing is
    /// final then, since the work of a turn may not have been seen yet.
    pub fn apply(
        &mut self,
        mut records: Vec<TurnMetric>,
        events: Vec<DelegationEvent>,
        now: DateTime<Utc>,
        backlog: bool,
    ) -> Vec<TurnMetric> {
        let mut turns: HashMap<String, (String, DateTime<Utc>)> = HashMap::new();
        for event in events {
            match event {
                DelegationEvent::Turn {
                    turn_id,
                    root_session,
                    started_at,
                } => {
                    turns.insert(turn_id, (root_session, started_at));
                }
                DelegationEvent::Started {
                    work_id,
                    root_session,
                    started_at,
                } => self.start(work_id, root_session, started_at),
                DelegationEvent::Finished {
                    work_id,
                    output_tokens,
                    finished_at,
                } => self.finish(&work_id, output_tokens, finished_at),
                DelegationEvent::Discarded { work_id } => self.discard(&work_id),
            }
        }

        let cutoff = now - Duration::days(RETENTION_DAYS);
        for record in &records {
            let Some((root_session, started_at)) = turns.get(&record.id) else {
                continue;
            };
            // Final records need no attribution; records older than the history retention are
            // never kept, so the work they would need is not either.
            if record.delegated_output_tokens.is_some() || record.completed_at < cutoff {
                continue;
            }
            self.pending.insert(
                record.id.clone(),
                PendingTurn {
                    root_session: root_session.clone(),
                    started_at: (*started_at).min(record.completed_at),
                    completed_at: record.completed_at,
                    metric: record.clone(),
                },
            );
        }
        self.prune(cutoff);

        let finals = self.finalize(now, backlog);
        if !finals.is_empty() {
            let positions: HashMap<String, usize> = records
                .iter()
                .enumerate()
                .map(|(index, record)| (record.id.clone(), index))
                .collect();
            for record in finals {
                match positions.get(&record.id) {
                    Some(index) => records[*index] = record,
                    None => records.push(record),
                }
            }
        }
        records
    }

    fn start(&mut self, work_id: String, root_session: String, started_at: DateTime<Utc>) {
        if let Some(item) = self.items.get_mut(&work_id) {
            // The same work is read again (live tail, then replay): finished work stands. Work
            // discarded by a reader that was reset is open again until its outcome is read.
            if item.state == WorkState::Discarded {
                item.state = WorkState::Open;
            }
            return;
        }
        self.by_root
            .entry(root_session.clone())
            .or_default()
            .insert(work_id.clone());
        self.items.insert(
            work_id,
            WorkItem {
                root_session,
                started_at,
                state: WorkState::Open,
            },
        );
    }

    fn finish(&mut self, work_id: &str, output_tokens: i64, finished_at: DateTime<Utc>) {
        let Some(item) = self.items.get_mut(work_id) else {
            return;
        };
        if item.state != WorkState::Open {
            return;
        }
        item.state = if output_tokens >= 0 && finished_at >= item.started_at {
            WorkState::Finished(output_tokens)
        } else {
            WorkState::Discarded
        };
    }

    fn discard(&mut self, work_id: &str) {
        if let Some(item) = self
            .items
            .get_mut(work_id)
            .filter(|item| item.state == WorkState::Open)
        {
            item.state = WorkState::Discarded;
        }
    }

    /// Drops what is older than the retention and enforces the hard caps, oldest first.
    fn prune(&mut self, cutoff: DateTime<Utc>) {
        self.pending.retain(|_, turn| turn.completed_at >= cutoff);
        if self.pending.len() > MAX_PENDING_TURNS {
            let mut by_age: Vec<(DateTime<Utc>, String)> = self
                .pending
                .iter()
                .map(|(id, turn)| (turn.completed_at, id.clone()))
                .collect();
            by_age.sort();
            // Evict a tenth at once so a long replay does not sort on every record.
            let excess = self.pending.len() - MAX_PENDING_TURNS * 9 / 10;
            for (_, id) in by_age.into_iter().take(excess) {
                self.pending.remove(&id);
            }
        }

        let mut evicted: Vec<String> = self
            .items
            .iter()
            .filter(|(_, item)| item.started_at < cutoff)
            .map(|(id, _)| id.clone())
            .collect();
        if self.items.len() - evicted.len() > MAX_WORK_ITEMS {
            let mut by_age: Vec<(DateTime<Utc>, String)> = self
                .items
                .iter()
                .filter(|(_, item)| item.started_at >= cutoff)
                .map(|(id, item)| (item.started_at, id.clone()))
                .collect();
            by_age.sort();
            let excess = by_age.len() - MAX_WORK_ITEMS * 9 / 10;
            evicted.extend(by_age.into_iter().take(excess).map(|(_, id)| id));
        }
        for id in evicted {
            if let Some(item) = self.items.remove(&id) {
                if let Some(ids) = self.by_root.get_mut(&item.root_session) {
                    ids.remove(&id);
                    if ids.is_empty() {
                        self.by_root.remove(&item.root_session);
                    }
                }
            }
        }
    }

    fn finalize(&mut self, now: DateTime<Utc>, backlog: bool) -> Vec<TurnMetric> {
        if backlog {
            return Vec::new();
        }
        let settle = Duration::seconds(DELEGATION_SETTLE_SECONDS);
        let max_wait = Duration::seconds(DELEGATION_MAX_WAIT_SECONDS);
        let mut ready: Vec<(String, i64)> = Vec::new();
        for (id, turn) in &self.pending {
            if now < turn.completed_at + settle {
                continue;
            }
            let mut total = 0_i64;
            let mut open = false;
            let work = self
                .by_root
                .get(&turn.root_session)
                .into_iter()
                .flatten()
                .filter_map(|work_id| self.items.get(work_id))
                .filter(|item| {
                    turn.started_at <= item.started_at && item.started_at <= turn.completed_at
                });
            for item in work {
                match item.state {
                    WorkState::Open => open = true,
                    WorkState::Finished(tokens) => total = total.saturating_add(tokens),
                    WorkState::Discarded => {}
                }
            }
            // Open work is awaited until the maximum wait, then ignored.
            if open && now < turn.completed_at + max_wait {
                continue;
            }
            ready.push((id.clone(), total));
        }
        ready
            .into_iter()
            .filter_map(|(id, total)| {
                self.pending
                    .remove(&id)
                    .map(|turn| turn.metric.with_delegated_output_tokens(total))
            })
            .collect()
    }
}
