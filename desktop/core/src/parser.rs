use crate::delegation::{root_session_key, DelegationEvent};
use crate::model::{
    response_qualifies, speed_is_plausible, ReportedReasoningEffort, ResponseMetric,
    ResponseTotals, TurnMetric,
};
use chrono::{DateTime, Duration, Utc};
use serde_json::{Map, Number, Value};
use sha2::{Digest, Sha256};
use std::collections::{HashMap, HashSet, VecDeque};

const MAX_LINE_BYTES: usize = 1_048_576;
const MAX_TRACKED_TURNS: usize = 4_096;
const MAX_EMITTED_TURNS: usize = 8_192;
const MAX_TURN_ID_BYTES: usize = 512;
const MAX_SESSION_ID_BYTES: usize = 512;
const MAX_PENDING_RESPONSES: usize = 1_024;

pub(crate) trait JsonlEventParser: Send {
    fn reset(&mut self, source_identity: String);
    fn consume(&mut self, line: &[u8]) -> Option<TurnMetric>;
    fn excludes_session(&self) -> bool;
    /// The reader started inside the file, after its header, so earlier records were never seen.
    fn begin_mid_file(&mut self) {}
    /// Closes work that was waiting for more records, once the reader has nothing more to read:
    /// a turn whose terminal message may still be written, or a complete tool-call response.
    /// `final_read` marks a complete (non-live) read of the file.
    fn flush_pending(&mut self, _now: DateTime<Utc>, _final_read: bool) -> Option<TurnMetric> {
        None
    }
    /// Qualifying responses completed since the last call (the live stream).
    fn take_responses(&mut self) -> Vec<ResponseMetric> {
        Vec::new()
    }
    /// Primary-turn and delegated-work events since the last call (the attribution stream).
    fn take_delegation_events(&mut self) -> Vec<DelegationEvent> {
        Vec::new()
    }
}

/// What a Codex rollout's first line says the session is.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum SessionKind {
    /// A user-facing session (or one whose source is not recognized): measured as turns.
    Primary,
    /// A `thread_spawn` child: read only to report delegated work, never measured as turns.
    DelegatedChild,
    /// Any other agent session (for example guardian approval reviews): skipped entirely.
    Excluded,
}

#[derive(Default)]
struct TurnState {
    started_at: Option<DateTime<Utc>>,
    /// This parser instance saw the turn's `task_started` event.
    start_observed: bool,
    output_tokens: Option<i64>,
    reasoning_output_tokens: Option<i64>,
    duration_milliseconds: Option<f64>,
    ttft_milliseconds: Option<f64>,
    model: Option<String>,
    model_was_ambiguous: bool,
    reasoning_effort: Option<String>,
    reasoning_effort_was_ambiguous: bool,
    /// Qualifying model responses of this turn (one per token-usage record).
    responses: ResponseTotals,
    response_ids: HashSet<String>,
    /// A delegated work item was reported as started for this turn.
    work_started: bool,
}

/// What `task_complete` measured for a turn.
struct MeasuredTurn {
    completed_at: DateTime<Utc>,
    duration: f64,
    output_tokens: i64,
    ttft: Option<f64>,
    throughput: f64,
}

/// Parser state is intentionally bounded. Source IDs are held only long enough to derive a digest.
pub(crate) struct CodexEventParser {
    source_identity: String,
    session_identity: Option<String>,
    turns: HashMap<String, TurnState>,
    turn_order: VecDeque<String>,
    emitted_turn_ids: HashSet<String>,
    emitted_order: VecDeque<String>,
    session_kind: SessionKind,
    /// Raw id of the root session: for primary sessions `session_id` else `id`, for delegated
    /// children `session_id` else `parent_thread_id`. Only ever digested, never kept elsewhere.
    root_session: Option<String>,
    delegation_events: Vec<DelegationEvent>,
    client_version: Option<String>,
    source_kind: String,
    provider: String,
    /// Latest turn start, user message or tool output: what triggers the next model request.
    latest_trigger: Option<DateTime<Utc>>,
    /// The trigger in force when the current response's first item arrived.
    response_start: Option<DateTime<Utc>>,
    responses: Vec<ResponseMetric>,
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
            session_kind: SessionKind::Primary,
            root_session: None,
            delegation_events: Vec::new(),
            client_version: None,
            source_kind: "unknown".to_owned(),
            provider: "unknown".to_owned(),
            latest_trigger: None,
            response_start: None,
            responses: Vec::new(),
        }
    }

    pub fn reset(&mut self, source_identity: String) {
        // Work this parser started will never be finished by it: settle it as discarded.
        let mut events = std::mem::take(&mut self.delegation_events);
        let open: Vec<String> = self
            .turns
            .iter()
            .filter(|(_, state)| state.work_started)
            .map(|(turn_id, _)| turn_id.clone())
            .collect();
        events.extend(open.iter().map(|turn_id| DelegationEvent::Discarded {
            work_id: self.turn_digest(turn_id),
        }));
        *self = Self::new(source_identity);
        self.delegation_events = events;
    }

    /// Only sessions that are neither primary nor delegated children stop being read.
    pub fn excludes_session(&self) -> bool {
        self.session_kind == SessionKind::Excluded
    }

    /// Local identity of one turn: the id of its metric and of its delegated work item.
    fn turn_digest(&self, turn_id: &str) -> String {
        let identity = self
            .session_identity
            .as_deref()
            .unwrap_or(&self.source_identity);
        let mut digest = Sha256::new();
        digest.update(identity.as_bytes());
        digest.update(b"|");
        digest.update(turn_id.as_bytes());
        format!("{:x}", digest.finalize())
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

        if event_type == "response_item" {
            self.consume_response_item(payload, parse_date(event.get("timestamp")));
            return None;
        }

        if event_type == "token_usage_record" {
            let turn_id = valid_turn_id(payload.get("turn_id")?)?;
            self.consume_response_usage(turn_id, payload, parse_date(event.get("timestamp")));
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

        if event_type != "event_msg" {
            return None;
        }
        let subtype = payload.get("type")?.as_str()?;
        if !matches!(subtype, "task_started" | "task_complete" | "turn_aborted") {
            return None;
        }
        let turn_id = valid_turn_id(payload.get("turn_id")?)?;
        let event_date = parse_date(event.get("timestamp"));

        if subtype == "turn_aborted" {
            // Only delegated work cares: an aborted child turn is discarded, never counted.
            self.discard_work(turn_id);
            return None;
        }

        if subtype == "task_started" {
            if let Some(date) = event_date {
                self.latest_trigger = Some(date);
                self.response_start = None;
            }
            let state = self.turn_state_mut(turn_id);
            state.start_observed = true;
            if state.started_at.is_none() {
                state.started_at = parse_date(payload.get("started_at")).or(event_date);
            }
            let started_at = state.started_at;
            let already_started = state.work_started;
            if self.session_kind == SessionKind::DelegatedChild && !already_started {
                self.start_work(turn_id, started_at);
            }
            return None;
        }

        let session_kind = self.session_kind;
        let already_emitted = self.emitted_turn_ids.contains(turn_id);
        let state = self.turn_state_mut(turn_id);
        if state.started_at.is_none() {
            state.started_at = parse_date(payload.get("started_at"));
        }
        if let Some(duration) = nonnegative_finite_number(payload.get("duration_ms")) {
            state.duration_milliseconds = Some(duration);
        }
        state.ttft_milliseconds = nonnegative_finite_number(payload.get("time_to_first_token_ms"));
        let start_observed = state.start_observed;
        let measured = measure_turn(state, payload, event_date);

        // A completion whose start this instance never saw (the reader began mid-turn) lacks its
        // turn context and cannot be measured faithfully.
        if session_kind == SessionKind::Excluded || already_emitted || !start_observed {
            return None;
        }
        if session_kind == SessionKind::DelegatedChild {
            // Children report work only: no TurnMetric, no live responses.
            self.finish_work(turn_id, measured.as_ref());
            return None;
        }
        let measured = measured
            .filter(|measured| speed_is_plausible(measured.output_tokens, measured.duration))?;

        self.remember_emitted(turn_id);
        self.turn_order.retain(|known| known != turn_id);
        let state = self.turns.remove(turn_id).unwrap_or_default();
        let (response_output_tokens, response_duration_seconds, response_count) =
            state.responses.fields();
        let id = self.turn_digest(turn_id);
        let completed_at = measured.completed_at;
        let started_at = state.started_at.unwrap_or_else(|| {
            completed_at
                - Duration::nanoseconds((measured.duration * 1e9).min(i64::MAX as f64) as i64)
        });

        let metric = TurnMetric {
            id: id.clone(),
            completed_at,
            model: if state.model_was_ambiguous {
                None
            } else {
                state.model
            },
            output_tokens: measured.output_tokens,
            duration_seconds: measured.duration,
            codex_ttft_seconds: measured.ttft,
            turn_throughput_tps: measured.throughput,
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
            response_output_tokens,
            response_duration_seconds,
            response_count,
            provider_region: None,
            delegated_output_tokens: None,
        };
        if self.source_kind == "primary" {
            // The root session joins this turn with the delegated work started during it.
            let root = self
                .root_session
                .as_deref()
                .unwrap_or(&self.source_identity);
            self.delegation_events.push(DelegationEvent::Turn {
                turn_id: id,
                root_session: root_session_key(crate::model::CODEX_CLIENT, root),
                started_at,
            });
        }
        Some(metric)
    }

    /// Reports a delegated work item for a turn of a delegated child session. Without a known
    /// root session the work cannot be attributed and is not reported.
    fn start_work(&mut self, turn_id: &str, started_at: Option<DateTime<Utc>>) {
        let (Some(root), Some(started_at)) = (self.root_session.as_deref(), started_at) else {
            return;
        };
        let event = DelegationEvent::Started {
            work_id: self.turn_digest(turn_id),
            root_session: root_session_key(crate::model::CODEX_CLIENT, root),
            started_at,
        };
        self.delegation_events.push(event);
        if let Some(state) = self.turns.get_mut(turn_id) {
            state.work_started = true;
        }
    }

    /// Settles the work item of a completed child turn: finished when it was measured, else
    /// discarded. The turn state is released either way.
    fn finish_work(&mut self, turn_id: &str, measured: Option<&MeasuredTurn>) {
        self.turn_order.retain(|known| known != turn_id);
        let Some(state) = self.turns.remove(turn_id) else {
            return;
        };
        if !state.work_started {
            return;
        }
        let work_id = self.turn_digest(turn_id);
        self.remember_emitted(turn_id);
        self.delegation_events.push(match measured {
            Some(measured) => DelegationEvent::Finished {
                work_id,
                output_tokens: measured.output_tokens,
                finished_at: measured.completed_at,
            },
            None => DelegationEvent::Discarded { work_id },
        });
    }

    /// An aborted or otherwise abandoned work item never counts.
    fn discard_work(&mut self, turn_id: &str) {
        if self.session_kind != SessionKind::DelegatedChild {
            return;
        }
        self.turn_order.retain(|known| known != turn_id);
        if self
            .turns
            .remove(turn_id)
            .is_some_and(|state| state.work_started)
        {
            let work_id = self.turn_digest(turn_id);
            self.delegation_events
                .push(DelegationEvent::Discarded { work_id });
        }
    }

    /// Tracks what triggers each model request. A user message or a tool output starts the next
    /// response; the first other item (reasoning, assistant text, a tool call) after it is the
    /// response's first item, and its trigger is the response start.
    fn consume_response_item(&mut self, payload: &Map<String, Value>, at: Option<DateTime<Utc>>) {
        let kind = payload.get("type").and_then(Value::as_str);
        let role = payload.get("role").and_then(Value::as_str);
        match (kind, role) {
            // Developer instructions are context: neither a request nor a model output.
            (Some("message"), Some("developer")) | (None, _) => {}
            // User messages and messages from other agents feed the model.
            (Some("message"), Some("user")) | (Some("agent_message"), _) => {
                self.latest_trigger = at.or(self.latest_trigger);
                self.response_start = None;
            }
            (Some(kind), _) if kind.ends_with("_output") => {
                self.latest_trigger = at.or(self.latest_trigger);
                self.response_start = None;
            }
            _ => {
                if self.response_start.is_none() {
                    self.response_start = self.latest_trigger;
                }
            }
        }
    }

    /// One `token_usage_record` closes one model response: its per-response `usage` output tokens,
    /// from its start (see [`Self::consume_response_item`]) to this record.
    fn consume_response_usage(
        &mut self,
        turn_id: &str,
        payload: &Map<String, Value>,
        at: Option<DateTime<Utc>>,
    ) {
        // Without a recorded first item the latest trigger still starts the response.
        let start = self.response_start.take().or(self.latest_trigger);
        let (Some(start), Some(end)) = (start, at) else {
            return;
        };
        let Some(tokens) = payload
            .get("usage")
            .and_then(Value::as_object)
            .and_then(|usage| nonnegative_integer(usage.get("output_tokens")))
        else {
            return;
        };
        let Some(nanos) = (end - start).num_nanoseconds() else {
            return;
        };
        let duration = nanos as f64 / 1e9;
        if !response_qualifies(tokens, duration) {
            return;
        }
        // A record without a response id cannot be told apart from a repeat and is not counted.
        let Some(response_id) = payload
            .get("response_id")
            .and_then(Value::as_str)
            .filter(|value| !value.is_empty() && value.len() <= MAX_TURN_ID_BYTES)
        else {
            return;
        };
        let state = self.turn_state_mut(turn_id);
        // A repeated record for the same response must not be counted twice.
        if !state.response_ids.insert(response_id.to_owned()) {
            return;
        }
        state.responses.add(tokens, duration);
        if self.session_kind != SessionKind::Primary {
            return;
        }
        let state = self.turn_state_mut(turn_id);
        // The live stream needs a single, known model.
        let model = match (&state.model, state.model_was_ambiguous) {
            (Some(model), false) => model.clone(),
            _ => return,
        };
        let reasoning_effort = if state.reasoning_effort_was_ambiguous {
            None
        } else {
            state.reasoning_effort.clone()
        };
        let identity = self
            .session_identity
            .as_deref()
            .unwrap_or(&self.source_identity);
        let mut digest = Sha256::new();
        for part in [
            "response",
            identity,
            turn_id,
            response_id,
            &end.to_rfc3339(),
        ] {
            digest.update(part.as_bytes());
            digest.update(b"|");
        }
        if self.responses.len() >= MAX_PENDING_RESPONSES {
            self.responses.remove(0);
        }
        self.responses.push(ResponseMetric {
            id: format!("{:x}", digest.finalize()),
            completed_at: end,
            model: Some(model),
            provider: Some(self.provider.clone()),
            client: crate::model::CODEX_CLIENT.to_owned(),
            source_kind: Some(self.source_kind.clone()),
            metric_version: crate::model::CODEX_METRIC_VERSION.to_owned(),
            reasoning_effort,
            output_tokens: tokens,
            duration_seconds: duration,
        });
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

        let source = payload.get("source").and_then(Value::as_object);
        let subagent = source.and_then(|source| source.get("subagent"));
        let id = payload
            .get("id")
            .and_then(Value::as_str)
            .filter(|id| !id.is_empty() && id.len() <= MAX_SESSION_ID_BYTES);
        if let Some(id) = id {
            self.session_identity = Some(id.to_owned());
        }
        let text_field = |key: &str| {
            payload
                .get(key)
                .and_then(Value::as_str)
                .filter(|value| !value.is_empty() && value.len() <= MAX_SESSION_ID_BYTES)
        };
        let session_id = text_field("session_id");
        let parent_thread_id = text_field("parent_thread_id");
        let is_agent_session = subagent.is_some()
            || payload
                .get("parent_thread_id")
                .and_then(Value::as_str)
                .is_some_and(|value| !value.is_empty())
            || payload
                .get("agent_path")
                .and_then(Value::as_str)
                .is_some_and(|value| !value.is_empty())
            || payload
                .get("agent_path")
                .and_then(Value::as_array)
                .is_some_and(|value| !value.is_empty());
        // Only spawned child threads are delegated work; every other agent kind, such as the
        // `other: "guardian"` approval reviews, stays skipped.
        let is_thread_spawn = subagent.and_then(Value::as_object).is_some_and(|kinds| {
            kinds.get("thread_spawn").is_some_and(Value::is_object) && !kinds.contains_key("other")
        });
        if is_agent_session {
            self.session_kind = if is_thread_spawn {
                SessionKind::DelegatedChild
            } else {
                SessionKind::Excluded
            };
        }
        self.root_session = match self.session_kind {
            SessionKind::DelegatedChild => session_id.or(parent_thread_id),
            _ => session_id.or(id),
        }
        .map(str::to_owned);
    }

    fn turn_state_mut(&mut self, turn_id: &str) -> &mut TurnState {
        if !self.turns.contains_key(turn_id) {
            if self.turns.len() >= MAX_TRACKED_TURNS {
                if let Some(oldest) = self.turn_order.pop_front() {
                    if self
                        .turns
                        .remove(&oldest)
                        .is_some_and(|state| state.work_started)
                    {
                        let work_id = self.turn_digest(&oldest);
                        self.delegation_events
                            .push(DelegationEvent::Discarded { work_id });
                    }
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

    fn take_responses(&mut self) -> Vec<ResponseMetric> {
        std::mem::take(&mut self.responses)
    }

    fn take_delegation_events(&mut self) -> Vec<DelegationEvent> {
        std::mem::take(&mut self.delegation_events)
    }
}

/// The measurements `task_complete` closes a turn with, or `None` when they are not valid.
fn measure_turn(
    state: &TurnState,
    payload: &Map<String, Value>,
    event_date: Option<DateTime<Utc>>,
) -> Option<MeasuredTurn> {
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
    Some(MeasuredTurn {
        completed_at,
        duration,
        output_tokens,
        ttft,
        throughput,
    })
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
