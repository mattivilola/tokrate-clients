//! The user's own provider-side failures of the last 24 hours (contract "Local provider errors
//! (0.1.23)"). Memory only: nothing here is persisted, exported or uploaded, and no error text
//! exists. Only this summary crosses into the webview snapshot.

use crate::model::{RequestOutcome, RequestOutcomeKind};
use chrono::{DateTime, Duration, Utc};
use serde::Serialize;
use std::collections::{HashMap, HashSet, VecDeque};

/// How long a failure stays in the summary.
pub const LOCAL_ERROR_WINDOW_HOURS: i64 = 24;
/// At most this many (client, model, kind) groups are kept; the group with the oldest failure goes
/// first.
pub const MAX_LOCAL_ERROR_GROUPS: usize = 200;
/// At most this many failures are remembered per group (the oldest go first), so a failure storm
/// cannot grow the memory without bound.
const MAX_FAILURES_PER_GROUP: usize = 1_000;
/// At most this many dedupe keys are remembered (the oldest go first).
pub(crate) const MAX_SEEN_KEYS: usize = 20_000;

/// The provider-side failure kinds shown locally. Successes never take part.
#[derive(Clone, Copy, Debug, Eq, Hash, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum ProviderErrorKind {
    Overloaded,
    ServerError,
    Throttled,
}

impl ProviderErrorKind {
    fn of(kind: RequestOutcomeKind) -> Option<Self> {
        match kind {
            RequestOutcomeKind::Succeeded => None,
            RequestOutcomeKind::Overloaded => Some(Self::Overloaded),
            RequestOutcomeKind::ServerError => Some(Self::ServerError),
            RequestOutcomeKind::Throttled => Some(Self::Throttled),
        }
    }
}

/// One group of the summary: how often a model of a coding tool failed in the last 24 hours and
/// when it last did.
#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ProviderErrorGroup {
    pub client: String,
    pub model: String,
    pub kind: ProviderErrorKind,
    pub count: usize,
    pub latest_at: DateTime<Utc>,
    /// For a throttled group: the plan usage (percent, rounded down) the latest failure showed
    /// quota left at, when it is known. Absent for every other kind.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub plan_used_percent: Option<u8>,
}

/// One remembered failure: when it happened and, for a throttled one, the plan usage then.
#[derive(Clone, Copy, Debug)]
pub(crate) struct Failure {
    at: DateTime<Utc>,
    plan_used_percent: Option<u8>,
}

#[derive(Clone, Debug, Eq, Hash, PartialEq)]
pub(crate) struct GroupKey {
    client: &'static str,
    model: String,
    kind: ProviderErrorKind,
}

/// Local, in-memory summary of the provider-side failures of the last 24 hours.
#[derive(Debug, Default)]
pub struct LocalProviderErrors {
    /// Failures per group, oldest first.
    pub(crate) groups: HashMap<GroupKey, VecDeque<Failure>>,
    pub(crate) seen: HashSet<String>,
    pub(crate) seen_order: VecDeque<(String, DateTime<Utc>)>,
}

impl LocalProviderErrors {
    pub fn new() -> Self {
        Self::default()
    }

    /// Takes in what a poll found: the failures among `outcomes` (an outcome already seen is
    /// ignored, one older than 24 hours is dropped, one stamped in the future counts as `now`),
    /// then forgets what has expired.
    pub fn ingest(&mut self, outcomes: &[RequestOutcome], now: DateTime<Utc>) {
        let cutoff = Self::cutoff(now);
        for outcome in outcomes {
            let Some(kind) = ProviderErrorKind::of(outcome.kind) else {
                continue;
            };
            let at = outcome.occurred_at.min(now);
            if at < cutoff || !self.seen.insert(outcome.dedupe_key.clone()) {
                continue;
            }
            self.seen_order.push_back((outcome.dedupe_key.clone(), at));
            self.record(
                GroupKey {
                    client: outcome.client,
                    model: outcome.model.clone(),
                    kind,
                },
                Failure {
                    at,
                    plan_used_percent: outcome.plan_used_percent,
                },
            );
        }
        self.prune(now);
    }

    /// Forgets the failures older than 24 hours, empty groups and the keys of both, and enforces
    /// the bounds.
    pub fn prune(&mut self, now: DateTime<Utc>) {
        let cutoff = Self::cutoff(now);
        self.groups.retain(|_, times| {
            while times.front().is_some_and(|failure| failure.at < cutoff) {
                times.pop_front();
            }
            !times.is_empty()
        });
        while self.seen_order.len() > MAX_SEEN_KEYS
            || self.seen_order.front().is_some_and(|(_, at)| *at < cutoff)
        {
            if let Some((key, _)) = self.seen_order.pop_front() {
                self.seen.remove(&key);
            }
        }
    }

    /// The groups with a failure in the last 24 hours, most recent failure first.
    pub fn summary(&self, now: DateTime<Utc>) -> Vec<ProviderErrorGroup> {
        let cutoff = Self::cutoff(now);
        let mut groups: Vec<ProviderErrorGroup> = self
            .groups
            .iter()
            .filter_map(|(key, times)| {
                let count = times.iter().filter(|failure| failure.at >= cutoff).count();
                let latest = times.back().filter(|failure| failure.at >= cutoff)?;
                Some(ProviderErrorGroup {
                    client: key.client.to_owned(),
                    model: key.model.clone(),
                    kind: key.kind,
                    count,
                    latest_at: latest.at,
                    plan_used_percent: latest.plan_used_percent,
                })
            })
            .collect();
        groups.sort_by(|a, b| {
            b.latest_at
                .cmp(&a.latest_at)
                .then_with(|| a.client.cmp(&b.client))
                .then_with(|| a.model.cmp(&b.model))
                .then_with(|| (a.kind as u8).cmp(&(b.kind as u8)))
        });
        groups
    }

    fn cutoff(now: DateTime<Utc>) -> DateTime<Utc> {
        now - Duration::hours(LOCAL_ERROR_WINDOW_HOURS)
    }

    fn record(&mut self, key: GroupKey, failure: Failure) {
        let at = failure.at;
        if !self.groups.contains_key(&key) && self.groups.len() >= MAX_LOCAL_ERROR_GROUPS {
            // Full: the group whose latest failure is the oldest makes room, unless the new
            // failure is older still.
            let oldest = self
                .groups
                .iter()
                .filter_map(|(key, times)| Some((times.back()?.at, key.clone())))
                .min_by(|a, b| a.0.cmp(&b.0).then_with(|| a.1.model.cmp(&b.1.model)));
            match oldest {
                Some((latest, evicted)) if latest <= at => {
                    self.groups.remove(&evicted);
                }
                _ => return,
            }
        }
        let times = self.groups.entry(key).or_default();
        let position = times.partition_point(|existing| existing.at <= at);
        times.insert(position, failure);
        if times.len() > MAX_FAILURES_PER_GROUP {
            times.pop_front();
        }
    }
}
