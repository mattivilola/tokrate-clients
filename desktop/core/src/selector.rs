use crate::model::{response_qualifies, ResponseMetric, TurnMetric};
use chrono::{DateTime, Duration, Utc};
use serde::Serialize;
use std::collections::HashMap;

/// Responses of the last ten minutes decide which model is the most active.
pub const AUTO_WINDOW_MINUTES: i64 = 10;
/// A challenger must lead continuously this long before it takes over.
pub const AUTO_LEAD_MINUTES: i64 = 2;
/// An active model without a qualifying response for this long is dropped immediately.
pub const AUTO_QUIET_MINUTES: i64 = 10;

/// A model as the user thinks of it: the model name and the route that served it.
#[derive(Clone, Debug, Eq, Hash, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ModelKey {
    pub model: Option<String>,
    pub provider: Option<String>,
}

impl ModelKey {
    pub fn of_response(response: &ResponseMetric) -> Self {
        Self::new(response.model.clone(), response.provider.clone())
    }

    pub fn of_turn(turn: &TurnMetric) -> Self {
        Self::new(turn.model.clone(), turn.provider.clone())
    }

    fn new(model: Option<String>, provider: Option<String>) -> Self {
        Self {
            model,
            provider: Some(provider.unwrap_or_else(|| "unknown".into())),
        }
    }
}

/// The persisted `selection` setting.
#[derive(Clone, Debug, Eq, PartialEq)]
pub enum SelectionMode {
    /// Follow the most active model, optionally within one coding tool.
    Auto { tool: Option<String> },
    /// Compare every model.
    All,
    /// A pinned model across tools and effort levels.
    Model(ModelKey),
    /// A pinned exact cohort (JSON array of its nine identity parts).
    Cohort(String),
}

const COHORT_PARTS: usize = 9;
const TOOLS: [&str; 3] = ["codex", "claude-code", "grok-build"];

impl SelectionMode {
    /// Parses a stored selection. `latest` (the pre-0.1.14 default) means `auto`.
    pub fn parse(value: &str) -> Option<Self> {
        match value {
            "auto" | "latest" => return Some(Self::Auto { tool: None }),
            "all" => return Some(Self::All),
            _ => {}
        }
        if let Some(tool) = value.strip_prefix("auto:") {
            return TOOLS.contains(&tool).then(|| Self::Auto {
                tool: Some(tool.to_owned()),
            });
        }
        if let Some(pinned) = value.strip_prefix("model:") {
            let parts: Vec<serde_json::Value> = serde_json::from_str(pinned).ok()?;
            let text = |part: &serde_json::Value| match part {
                serde_json::Value::Null => Some(None),
                serde_json::Value::String(text) => Some(Some(text.clone())),
                _ => None,
            };
            return match parts.as_slice() {
                [model, provider] => Some(Self::Model(ModelKey {
                    model: text(model)?,
                    provider: text(provider)?,
                })),
                _ => None,
            };
        }
        serde_json::from_str::<Vec<serde_json::Value>>(value)
            .is_ok_and(|parts| parts.len() == COHORT_PARTS)
            .then(|| Self::Cohort(value.to_owned()))
    }

    /// Canonical stored form; `None` for an invalid value.
    pub fn normalize(value: &str) -> Option<String> {
        match Self::parse(value)? {
            Self::Auto { tool: None } => Some("auto".into()),
            _ => Some(value.to_owned()),
        }
    }

    pub fn tool(&self) -> Option<&str> {
        match self {
            Self::Auto { tool } => tool.as_deref(),
            _ => None,
        }
    }
}

/// Picks the active model of an Auto selection from the live response stream, with hysteresis.
/// Pure: every call receives the clock, so tests drive time directly.
#[derive(Debug, Default)]
pub struct AutoSelector {
    active: Option<ModelKey>,
    tool: Option<String>,
    leader: Option<(ModelKey, DateTime<Utc>)>,
}

impl AutoSelector {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn active(&self) -> Option<&ModelKey> {
        self.active.as_ref()
    }

    /// Re-evaluates the active model. `live` may be in any order; only qualifying responses (200+
    /// output tokens) of the last ten minutes, within `tool` when given, count. Returns the
    /// active model, or `None` when there is no recent live response (the caller falls back to
    /// the most recent turn).
    pub fn update(
        &mut self,
        now: DateTime<Utc>,
        live: &[ResponseMetric],
        tool: Option<&str>,
    ) -> Option<&ModelKey> {
        if self.tool.as_deref() != tool {
            *self = Self {
                tool: tool.map(str::to_owned),
                ..Self::default()
            };
        }
        let window_start = now - Duration::minutes(AUTO_WINDOW_MINUTES);
        let mut tokens: HashMap<ModelKey, (i64, DateTime<Utc>)> = HashMap::new();
        for response in live.iter().filter(|response| {
            response.completed_at > window_start
                && response.completed_at <= now
                && response.output_tokens >= crate::model::RESPONSE_MIN_OUTPUT_TOKENS
                && response_qualifies(response.output_tokens, response.duration_seconds)
                && tool.map_or(true, |tool| tool == response.client)
        }) {
            let entry = tokens
                .entry(ModelKey::of_response(response))
                .or_insert((0, response.completed_at));
            entry.0 += response.output_tokens;
            entry.1 = entry.1.max(response.completed_at);
        }
        // The busiest model wins; ties go to the one that responded last.
        let candidate = tokens
            .iter()
            .max_by(|left, right| {
                left.1
                    .cmp(right.1)
                    .then_with(|| right.0.model.cmp(&left.0.model))
            })
            .map(|(key, _)| key.clone());
        let Some(candidate) = candidate else {
            // Nothing in ten minutes: the active model has been quiet that long.
            self.active = None;
            self.leader = None;
            return None;
        };
        let active_quiet = self
            .active
            .as_ref()
            .map_or(true, |active| !tokens.contains_key(active));
        if active_quiet {
            self.active = Some(candidate);
            self.leader = None;
        } else if self.active.as_ref() == Some(&candidate) {
            self.leader = None;
        } else {
            let since = match self.leader.as_ref() {
                Some((leader, since)) if *leader == candidate => *since,
                _ => now,
            };
            if now - since >= Duration::minutes(AUTO_LEAD_MINUTES) {
                self.active = Some(candidate);
                self.leader = None;
            } else {
                self.leader = Some((candidate, since));
            }
        }
        self.active.as_ref()
    }
}

/// With no live responses: the model of the most recent turn that has response data, else of the
/// most recent turn. `turns` is newest first.
pub fn fallback_model(turns: &[TurnMetric], tool: Option<&str>) -> Option<ModelKey> {
    let mut matching = turns
        .iter()
        .filter(|turn| tool.map_or(true, |tool| tool == turn.client));
    let first = matching.clone().next()?;
    let chosen = matching
        .find(|turn| turn.response_count.is_some_and(|count| count > 0))
        .unwrap_or(first);
    Some(ModelKey::of_turn(chosen))
}
