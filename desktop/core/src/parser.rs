use crate::model::{ReportedReasoningEffort, TurnMetric};
use chrono::{DateTime, Utc};
use serde_json::{Map, Number, Value};
use sha2::{Digest, Sha256};
use std::collections::{HashMap, HashSet, VecDeque};

const MAX_LINE_BYTES: usize = 1_048_576;
const MAX_TRACKED_TURNS: usize = 4_096;
const MAX_EMITTED_TURNS: usize = 8_192;
const MAX_TURN_ID_BYTES: usize = 512;
const MAX_SESSION_ID_BYTES: usize = 512;

pub(crate) trait JsonlEventParser: Send {
    fn reset(&mut self, source_identity: String);
    fn consume(&mut self, line: &[u8]) -> Option<TurnMetric>;
    fn excludes_session(&self) -> bool;
}

#[derive(Default)]
struct TurnState {
    started_at: Option<DateTime<Utc>>,
    output_tokens: Option<i64>,
    reasoning_output_tokens: Option<i64>,
    duration_milliseconds: Option<f64>,
    ttft_milliseconds: Option<f64>,
    model: Option<String>,
    model_was_ambiguous: bool,
    reasoning_effort: Option<String>,
    reasoning_effort_was_ambiguous: bool,
}

/// Parser state is intentionally bounded. Source IDs are held only long enough to derive a digest.
pub(crate) struct CodexEventParser {
    source_identity: String,
    session_identity: Option<String>,
    turns: HashMap<String, TurnState>,
    turn_order: VecDeque<String>,
    emitted_turn_ids: HashSet<String>,
    emitted_order: VecDeque<String>,
    is_agent_session: bool,
    client_version: Option<String>,
    source_kind: String,
    provider: String,
}

impl CodexEventParser {
    pub fn new(source_identity: String) -> Self {
        Self {
            source_identity,
            session_identity: None,
            turns: HashMap::new(),
            turn_order: VecDeque::new(),
            emitted_turn_ids: HashSet::new(),
            emitted_order: VecDeque::new(),
            is_agent_session: false,
            client_version: None,
            source_kind: "unknown".to_owned(),
            provider: "unknown".to_owned(),
        }
    }

    pub fn reset(&mut self, source_identity: String) {
        *self = Self::new(source_identity);
    }

    pub fn excludes_session(&self) -> bool {
        self.is_agent_session
    }

    pub fn consume(&mut self, line: &[u8]) -> Option<TurnMetric> {
        if line.len() > MAX_LINE_BYTES {
            return None;
        }
        let root: Value = serde_json::from_slice(line).ok()?;
        let event = root.as_object()?;
        let event_type = event.get("type")?.as_str()?;
        let payload = event.get("payload")?.as_object()?;

        if event_type == "session_meta" {
            self.consume_session_meta(payload);
            return None;
        }

        if event_type == "turn_context" {
            let turn_id = valid_turn_id(payload.get("turn_id")?)?;
            let state = self.turn_state_mut(turn_id);
            update_model(payload.get("model").and_then(Value::as_str), state);
            update_reasoning_effort(payload.get("effort"), state);
            return None;
        }

        if event_type == "token_usage_record" {
            let turn_id = valid_turn_id(payload.get("turn_id")?)?;
            let state = self.turn_state_mut(turn_id);
            if let Some(usage) = payload.get("turn_token_usage").and_then(Value::as_object) {
                if let Some(output) = nonnegative_integer(usage.get("output_tokens")) {
                    // Usage records are cumulative snapshots, so the newest valid total wins.
                    state.output_tokens = Some(output);
                    state.reasoning_output_tokens =
                        nonnegative_integer(usage.get("reasoning_output_tokens"));
                }
            }
            return None;
        }

        if event_type != "event_msg"
            || payload.get("type").and_then(Value::as_str) != Some("task_started")
                && payload.get("type").and_then(Value::as_str) != Some("task_complete")
        {
            return None;
        }

        let subtype = payload.get("type")?.as_str()?;
        let turn_id = valid_turn_id(payload.get("turn_id")?)?;
        let event_date = parse_date(event.get("timestamp"));

        if subtype == "task_started" {
            let state = self.turn_state_mut(turn_id);
            if state.started_at.is_none() {
                state.started_at = parse_date(payload.get("started_at")).or(event_date);
            }
            return None;
        }

        let is_agent_session = self.is_agent_session;
        let already_emitted = self.emitted_turn_ids.contains(turn_id);
        let state = self.turn_state_mut(turn_id);
        if state.started_at.is_none() {
            state.started_at = parse_date(payload.get("started_at"));
        }
        if let Some(duration) = nonnegative_finite_number(payload.get("duration_ms")) {
            state.duration_milliseconds = Some(duration);
        }
        state.ttft_milliseconds = nonnegative_finite_number(payload.get("time_to_first_token_ms"));

        let completed_at = parse_date(payload.get("completed_at")).or(event_date)?;
        let duration = state
            .duration_milliseconds
            .map(|value| value / 1_000.0)
            .or_else(|| {
                state.started_at.and_then(|start| {
                    (completed_at - start)
                        .num_nanoseconds()
                        .map(|nanos| nanos as f64 / 1e9)
                })
            })?;

        if is_agent_session || already_emitted {
            return None;
        }
        let output_tokens = state.output_tokens?;
        if !duration.is_finite() || duration <= 0.0 || output_tokens < 0 {
            return None;
        }
        let ttft = state.ttft_milliseconds.map(|value| value / 1_000.0);
        if ttft.is_some_and(|value| !value.is_finite()) {
            return None;
        }
        let throughput = output_tokens as f64 / duration;
        if !throughput.is_finite() || throughput < 0.0 {
            return None;
        }

        self.remember_emitted(turn_id);
        self.turn_order.retain(|known| known != turn_id);
        let state = self.turns.remove(turn_id).unwrap_or_default();
        let identity = self
            .session_identity
            .as_deref()
            .unwrap_or(&self.source_identity);
        let mut digest = Sha256::new();
        digest.update(identity.as_bytes());
        digest.update(b"|");
        digest.update(turn_id.as_bytes());
        let id = format!("{:x}", digest.finalize());

        Some(TurnMetric {
            id,
            completed_at,
            model: if state.model_was_ambiguous {
                None
            } else {
                state.model
            },
            output_tokens,
            duration_seconds: duration,
            codex_ttft_seconds: ttft,
            turn_throughput_tps: throughput,
            streaming_tps: None,
            client_version: self.client_version.clone(),
            client: crate::model::CODEX_CLIENT.to_owned(),
            parser_version: crate::model::CODEX_PARSER_VERSION.to_owned(),
            metric_version: crate::model::CODEX_METRIC_VERSION.to_owned(),
            reasoning_output_tokens: state.reasoning_output_tokens,
            source_kind: Some(self.source_kind.clone()),
            provider: Some(self.provider.clone()),
            reasoning_effort: if state.reasoning_effort_was_ambiguous {
                None
            } else {
                state.reasoning_effort
            },
        })
    }

    fn consume_session_meta(&mut self, payload: &Map<String, Value>) {
        self.client_version = payload
            .get("cli_version")
            .and_then(Value::as_str)
            .filter(|value| safe_identifier(value, 40, true))
            .map(str::to_owned);
        self.provider = if payload.get("model_provider").and_then(Value::as_str) == Some("openai") {
            "openai".to_owned()
        } else {
            "unknown".to_owned()
        };
        self.source_kind = if payload
            .get("source")
            .and_then(Value::as_str)
            .is_some_and(|source| matches!(source, "cli" | "vscode" | "exec" | "desktop" | "app"))
        {
            "primary".to_owned()
        } else {
            "unknown".to_owned()
        };

        if let Some(source) = payload.get("source").and_then(Value::as_object) {
            if source.contains_key("subagent") {
                self.is_agent_session = true;
            }
        }
        if let Some(id) = payload
            .get("id")
            .and_then(Value::as_str)
            .filter(|id| !id.is_empty() && id.len() <= MAX_SESSION_ID_BYTES)
        {
            self.session_identity = Some(id.to_owned());
        }
        if payload
            .get("parent_thread_id")
            .and_then(Value::as_str)
            .is_some_and(|value| !value.is_empty())
        {
            self.is_agent_session = true;
        }
        if payload
            .get("agent_path")
            .and_then(Value::as_str)
            .is_some_and(|value| !value.is_empty())
            || payload
                .get("agent_path")
                .and_then(Value::as_array)
                .is_some_and(|value| !value.is_empty())
        {
            self.is_agent_session = true;
        }
    }

    fn turn_state_mut(&mut self, turn_id: &str) -> &mut TurnState {
        if !self.turns.contains_key(turn_id) {
            if self.turns.len() >= MAX_TRACKED_TURNS {
                if let Some(oldest) = self.turn_order.pop_front() {
                    self.turns.remove(&oldest);
                }
            }
            self.turn_order.push_back(turn_id.to_owned());
            self.turns.insert(turn_id.to_owned(), TurnState::default());
        }
        self.turns.get_mut(turn_id).expect("inserted turn state")
    }

    fn remember_emitted(&mut self, turn_id: &str) {
        if !self.emitted_turn_ids.insert(turn_id.to_owned()) {
            return;
        }
        self.emitted_order.push_back(turn_id.to_owned());
        while self.emitted_order.len() > MAX_EMITTED_TURNS {
            if let Some(oldest) = self.emitted_order.pop_front() {
                self.emitted_turn_ids.remove(&oldest);
            }
        }
    }
}

impl JsonlEventParser for CodexEventParser {
    fn reset(&mut self, source_identity: String) {
        CodexEventParser::reset(self, source_identity)
    }

    fn consume(&mut self, line: &[u8]) -> Option<TurnMetric> {
        CodexEventParser::consume(self, line)
    }

    fn excludes_session(&self) -> bool {
        CodexEventParser::excludes_session(self)
    }
}

fn valid_turn_id(value: &Value) -> Option<&str> {
    value
        .as_str()
        .filter(|value| !value.is_empty() && value.len() <= MAX_TURN_ID_BYTES)
}

fn update_model(model: Option<&str>, state: &mut TurnState) {
    let Some(model) = model.filter(|model| safe_identifier(model, 80, false)) else {
        return;
    };
    if state
        .model
        .as_deref()
        .is_some_and(|previous| previous != model)
    {
        state.model_was_ambiguous = true;
    }
    if state.model.is_none() && !state.model_was_ambiguous {
        state.model = Some(model.to_owned());
    }
}

fn update_reasoning_effort(value: Option<&Value>, state: &mut TurnState) {
    if state.reasoning_effort_was_ambiguous {
        return;
    }
    let value = value
        .and_then(Value::as_str)
        .filter(|value| ReportedReasoningEffort::is_allowed(value));
    let Some(value) = value else {
        state.reasoning_effort = None;
        state.reasoning_effort_was_ambiguous = true;
        return;
    };
    if state
        .reasoning_effort
        .as_deref()
        .is_some_and(|previous| previous != value)
    {
        state.reasoning_effort = None;
        state.reasoning_effort_was_ambiguous = true;
    } else {
        state.reasoning_effort = Some(value.to_owned());
    }
}

fn safe_identifier(value: &str, maximum: usize, plus_allowed: bool) -> bool {
    !value.is_empty()
        && value.len() <= maximum
        && value.bytes().all(|byte| {
            byte.is_ascii_alphanumeric()
                || matches!(byte, b'.' | b'_' | b'-')
                || plus_allowed && byte == b'+'
        })
}

fn nonnegative_integer(value: Option<&Value>) -> Option<i64> {
    let number = value?.as_number()?;
    let parsed = number_as_f64(number)?;
    if !parsed.is_finite() || parsed < 0.0 || parsed.fract() != 0.0 || parsed >= i64::MAX as f64 {
        return None;
    }
    Some(parsed as i64)
}

fn nonnegative_finite_number(value: Option<&Value>) -> Option<f64> {
    let number = value?.as_number()?;
    let parsed = number_as_f64(number)?;
    (parsed.is_finite() && parsed >= 0.0).then_some(parsed)
}

fn number_as_f64(number: &Number) -> Option<f64> {
    number.as_f64()
}

fn parse_date(value: Option<&Value>) -> Option<DateTime<Utc>> {
    let value = value?.as_str()?;
    DateTime::parse_from_rfc3339(value)
        .ok()
        .map(|date| date.with_timezone(&Utc))
}
