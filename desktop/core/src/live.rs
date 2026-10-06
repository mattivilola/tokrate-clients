use crate::model::{response_qualifies, ResponseMetric, TurnMetric, GROK_CLIENT};
use chrono::{DateTime, Duration, Utc};
use std::collections::{HashSet, VecDeque};

/// The in-memory live stream keeps this many of the newest responses.
pub const LIVE_CAPACITY: usize = 200;
/// The live speed is the median of this many newest responses...
pub const LIVE_VALUE_COUNT: usize = 5;
/// ...that all finished within this window.
pub const LIVE_VALUE_WINDOW_MINUTES: i64 = 10;
/// A response may not finish in the future; this much clock skew is tolerated.
const FUTURE_TOLERANCE_SECONDS: i64 = 120;

/// Which live responses belong to the selected model. Provider `None` and `unknown` are the same.
#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub struct LiveScope {
    pub model: Option<String>,
    pub provider: Option<String>,
    /// Restricts to one coding tool (pinned cohorts and "Auto within a coding tool").
    pub client: Option<String>,
}

impl LiveScope {
    pub fn matches(&self, response: &ResponseMetric) -> bool {
        let provider = |value: &Option<String>| value.clone().unwrap_or_else(|| "unknown".into());
        self.model == response.model
            && provider(&self.provider) == provider(&response.provider)
            && self
                .client
                .as_deref()
                .map_or(true, |client| client == response.client)
    }
}

impl ResponseMetric {
    /// The live response a completed Grok Build turn amounts to. Grok records output per turn, not
    /// per response, so the turn's response timing (a whole-turn average over its model calls) is
    /// the response: it needs a model, a primary source and response fields that pass the same
    /// thresholds as any response. The turn id identifies it, so the same turn is never counted twice.
    pub fn from_grok_turn(turn: &TurnMetric) -> Option<Self> {
        let output_tokens = turn.response_output_tokens?;
        let duration_seconds = turn.response_duration_seconds?;
        (turn.client == GROK_CLIENT
            && turn.model.is_some()
            && turn.source_kind.as_deref() == Some("primary")
            && response_qualifies(output_tokens, duration_seconds))
        .then(|| Self {
            id: turn.id.clone(),
            completed_at: turn.completed_at,
            model: turn.model.clone(),
            provider: turn.provider.clone(),
            client: turn.client.clone(),
            source_kind: turn.source_kind.clone(),
            metric_version: turn.metric_version.clone(),
            reasoning_effort: turn.reasoning_effort.clone(),
            output_tokens,
            duration_seconds,
        })
    }
}

/// The headline "last 5 responses" reading.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct LiveValue {
    /// Median response speed in tokens per second.
    pub speed: f64,
    pub count: usize,
    pub last_at: DateTime<Utc>,
}

/// Bounded in-memory stream of qualifying responses completed after the app started.
/// It is never persisted, shared or replayed from history.
pub struct LiveResponses {
    started_at: DateTime<Utc>,
    buffer: VecDeque<ResponseMetric>,
    ids: HashSet<String>,
}

impl LiveResponses {
    pub fn new(started_at: DateTime<Utc>) -> Self {
        Self {
            started_at,
            buffer: VecDeque::new(),
            ids: HashSet::new(),
        }
    }

    /// Adds responses that qualify, finished after the start and are not already known.
    /// Returns true when the stream changed.
    pub fn push(&mut self, responses: Vec<ResponseMetric>, now: DateTime<Utc>) -> bool {
        let latest = now + Duration::seconds(FUTURE_TOLERANCE_SECONDS);
        let mut changed = false;
        for response in responses {
            if response.completed_at < self.started_at
                || response.completed_at > latest
                || !response_qualifies(response.output_tokens, response.duration_seconds)
                || !self.ids.insert(response.id.clone())
            {
                continue;
            }
            self.buffer.push_back(response);
            changed = true;
        }
        if changed {
            self.buffer
                .make_contiguous()
                .sort_by(|left, right| left.completed_at.cmp(&right.completed_at));
            while self.buffer.len() > LIVE_CAPACITY {
                if let Some(oldest) = self.buffer.pop_front() {
                    self.ids.remove(&oldest.id);
                }
            }
        }
        changed
    }

    /// Oldest first.
    pub fn responses(&self) -> Vec<ResponseMetric> {
        self.buffer.iter().cloned().collect()
    }

    pub fn len(&self) -> usize {
        self.buffer.len()
    }

    pub fn is_empty(&self) -> bool {
        self.buffer.is_empty()
    }

    /// The newest matching responses of the live window, newest first.
    fn newest(&self, now: DateTime<Utc>, scope: &LiveScope) -> Vec<&ResponseMetric> {
        let oldest = now - Duration::minutes(LIVE_VALUE_WINDOW_MINUTES);
        self.buffer
            .iter()
            .rev()
            .filter(|response| {
                response.completed_at >= oldest
                    && response.completed_at <= now
                    && scope.matches(response)
            })
            .take(LIVE_VALUE_COUNT)
            .collect()
    }

    /// The coding tool of the newest response [`LiveResponses::value`] would include.
    pub fn latest_client(&self, now: DateTime<Utc>, scope: &LiveScope) -> Option<String> {
        self.newest(now, scope)
            .first()
            .map(|response| response.client.clone())
    }

    /// Median of the newest five matching responses finished within the last ten minutes.
    pub fn value(&self, now: DateTime<Utc>, scope: &LiveScope) -> Option<LiveValue> {
        let newest = self.newest(now, scope);
        let last_at = newest.first()?.completed_at;
        let mut speeds: Vec<f64> = newest.iter().map(|response| response.speed()).collect();
        speeds.sort_by(|left, right| left.total_cmp(right));
        let middle = speeds.len() / 2;
        let speed = if speeds.len() % 2 == 1 {
            speeds[middle]
        } else {
            (speeds[middle - 1] + speeds[middle]) / 2.0
        };
        Some(LiveValue {
            speed,
            count: speeds.len(),
            last_at,
        })
    }
}
