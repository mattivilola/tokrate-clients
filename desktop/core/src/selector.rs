use crate::live::{LiveResponses, LiveScope};
use crate::model::{response_qualifies, ResponseMetric, TurnMetric};
use chrono::{DateTime, Duration, Utc};
use serde::Serialize;
use std::collections::HashMap;

/// Responses of the last three minutes decide which model is the most active. An active model with
/// no qualifying response left in this window is quiet and is replaced at once.
pub const AUTO_WINDOW_MINUTES: i64 = 3;
/// A challenger must lead continuously this long before it takes over.
pub const AUTO_LEAD_SECONDS: i64 = 30;

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
const TOOLS: [&str; 6] = [
    "codex",
    "claude-code",
    "grok-build",
    "antigravity",
    "opencode",
    "kimi-code",
];

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
    /// output tokens) of the last three minutes, within `tool` when given, count. Returns the
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
            // Nothing in the window: the active model has gone quiet.
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
            if now - since >= Duration::seconds(AUTO_LEAD_SECONDS) {
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

/// Which measurement a [`TrayReading`] is.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum TrayReadingKind {
    /// The median of the newest live responses.
    Live,
    /// The response speed of the scope's newest turn with response timing.
    LatestResponse,
    /// The whole-turn speed of the scope's newest turn long enough to count: nothing has response
    /// timing.
    TurnFallback,
}

/// What the tray shows and for which model and coding tool.
#[derive(Clone, Debug, PartialEq)]
pub struct TrayReading {
    /// Tokens per second.
    pub speed: f64,
    pub kind: TrayReadingKind,
    pub model: Option<String>,
    /// `unknown` when the route is not known, as in [`ModelKey`].
    pub provider: Option<String>,
    /// The coding tool the value comes from.
    pub client: String,
}

const RETENTION_DAYS: i64 = 7;
/// A turn shorter than this is too small for a throughput (the dashboard's eligibility).
const MIN_THROUGHPUT_OUTPUT_TOKENS: i64 = 20;

/// Output tokens per second while the model was responding; `None` without response timing.
fn response_speed(turn: &TurnMetric) -> Option<f64> {
    let (tokens, seconds) = (
        turn.response_output_tokens?,
        turn.response_duration_seconds?,
    );
    let speed = tokens as f64 / seconds;
    (tokens > 0 && seconds > 0.0 && speed.is_finite()).then_some(speed)
}

/// The nine identity parts of a turn's exact cohort, as the UI pins them.
fn cohort_parts(turn: &TurnMetric) -> Vec<serde_json::Value> {
    use serde_json::Value::{Null, String as Text};
    let optional = |value: &Option<String>| value.clone().map_or(Null, Text);
    vec![
        Text(turn.client.clone()),
        optional(&turn.client_version),
        Text(turn.parser_version.clone()),
        Text(turn.metric_version.clone()),
        optional(&turn.model),
        optional(&turn.provider),
        optional(&turn.provider_region),
        optional(&turn.reasoning_effort),
        optional(&turn.source_kind),
    ]
}

fn is_model(turn: &TurnMetric, key: &ModelKey) -> bool {
    ModelKey::of_turn(turn) == *key
}

/// The value the tray shows, chosen exactly as the dashboard hero chooses its value: the live
/// median of the followed model, else the newest turn with response timing in its scope, else (the
/// tray's last resort) that scope's newest turn long enough to have a throughput.
///
/// The followed model is the live `active` model of an Auto selection (else the newest turn with
/// response timing in the tool's turns), or the pinned model or cohort. `tool` and `provider` are
/// the dashboard's tool and provider filters (`None` is "all"); they narrow the turns, not the live
/// stream, as in the dashboard. A pinned cohort that has left the seven-day window behaves like
/// Auto. "All" has no hero on the dashboard; the tray follows the active model without a tool
/// restriction then. `turns` is newest first.
pub fn tray_reading(
    selection: &SelectionMode,
    live: &LiveResponses,
    active: Option<&ModelKey>,
    turns: &[TurnMetric],
    tool: Option<&str>,
    provider: Option<&str>,
    now: DateTime<Utc>,
) -> Option<TrayReading> {
    let oldest = now - Duration::days(RETENTION_DAYS);
    let filtered: Vec<&TurnMetric> = turns
        .iter()
        .filter(|turn| {
            turn.completed_at >= oldest
                && turn.completed_at <= now
                && tool.map_or(true, |tool| tool == turn.client)
                && provider.map_or(true, |provider| {
                    provider == turn.provider.as_deref().unwrap_or("unknown")
                })
        })
        .collect();

    let cohort = match selection {
        SelectionMode::Cohort(key) => serde_json::from_str::<Vec<serde_json::Value>>(key)
            .ok()
            .filter(|parts| filtered.iter().any(|turn| cohort_parts(turn) == *parts)),
        _ => None,
    };
    let auto_tool = match selection {
        SelectionMode::Auto { tool } => tool.as_deref(),
        _ => None,
    };
    let auto_pool: Vec<&TurnMetric> = filtered
        .iter()
        .copied()
        .filter(|turn| auto_tool.map_or(true, |tool| tool == turn.client))
        .collect();
    let newest_with_response = |pool: &[&TurnMetric]| -> Option<ModelKey> {
        pool.iter()
            .find(|turn| response_speed(turn).is_some())
            .or_else(|| pool.first())
            .map(|turn| ModelKey::of_turn(turn))
    };

    let (key, scope_client) = match (&cohort, selection) {
        (Some(parts), _) => {
            let text = |index: usize| parts[index].as_str().map(str::to_owned);
            let key = ModelKey {
                model: text(4),
                provider: Some(text(5).unwrap_or_else(|| "unknown".into())),
            };
            (Some(key), text(0))
        }
        (None, SelectionMode::Model(key)) => (
            Some(ModelKey {
                model: key.model.clone(),
                provider: Some(key.provider.clone().unwrap_or_else(|| "unknown".into())),
            }),
            None,
        ),
        // Auto, All, and a cohort that left the window.
        _ => (
            active.cloned().or_else(|| newest_with_response(&auto_pool)),
            auto_tool.map(str::to_owned),
        ),
    };
    let key = key?;

    let scope = LiveScope {
        model: key.model.clone(),
        provider: key.provider.clone(),
        client: scope_client,
    };
    if let Some(value) = live.value(now, &scope) {
        return Some(TrayReading {
            speed: value.speed,
            kind: TrayReadingKind::Live,
            model: key.model,
            provider: key.provider,
            client: live.latest_client(now, &scope)?,
        });
    }

    let scope_turns = filtered.iter().copied().filter(|turn| match &cohort {
        Some(parts) => cohort_parts(turn) == *parts,
        None => auto_tool.map_or(true, |tool| tool == turn.client) && is_model(turn, &key),
    });
    let reading = |turn: &TurnMetric, speed: f64, kind: TrayReadingKind| TrayReading {
        speed,
        kind,
        model: turn.model.clone(),
        provider: ModelKey::of_turn(turn).provider,
        client: turn.client.clone(),
    };
    let scope_turns: Vec<&TurnMetric> = scope_turns.collect();
    scope_turns
        .iter()
        .find_map(|turn| {
            response_speed(turn).map(|speed| reading(turn, speed, TrayReadingKind::LatestResponse))
        })
        .or_else(|| {
            scope_turns
                .iter()
                .find(|turn| turn.output_tokens >= MIN_THROUGHPUT_OUTPUT_TOKENS)
                .map(|turn| {
                    reading(
                        turn,
                        turn.turn_throughput_tps,
                        TrayReadingKind::TurnFallback,
                    )
                })
        })
}
