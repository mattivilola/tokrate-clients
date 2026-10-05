use crate::delegation::{root_session_key, DelegationEvent};
use crate::model::{
    bedrock_region_or_unknown, response_qualifies, ReportedReasoningEffort, ResponseMetric,
    ResponseTotals, TurnMetric, CLAUDE_CLIENT, CLAUDE_METRIC_VERSION, CLAUDE_PARSER_VERSION,
    CLAUDE_SUBAGENT_METRIC_VERSION,
};
use crate::parser::JsonlEventParser;
use chrono::{DateTime, Duration, Utc};
use serde_json::Value;
use sha2::{Digest, Sha256};
use std::collections::{HashMap, HashSet, VecDeque};
use std::path::Path;

const MAX_TRACKED_MESSAGES: usize = 4_096;
const MAX_EMITTED_TURNS: usize = 8_192;
/// Records remembered per file to resolve response parents.
const MAX_REMEMBERED_RECORDS: usize = 4_096;
const MAX_CLOSED_RESPONSES: usize = 4_096;
/// Completed responses wait here until the reader drains them after each poll.
const MAX_PENDING_RESPONSES: usize = 1_024;
/// A terminal message still ending in thinking may wait this long for its text.
const PENDING_TURN_TIMEOUT_SECONDS: i64 = 30;
const MAX_IDENTIFIER_BYTES: usize = 512;
/// A human message this soon after the turn's last activity continues that turn.
const INTERJECTION_CONTINUATION_MINUTES: i64 = 30;
const INTERRUPTION_MARKER: &str = "[Request interrupted by user";
const SYNTHETIC_MODEL: &str = "<synthetic>";

/// Which transcript records a parser instance measures.
#[derive(Clone, Copy, Eq, PartialEq)]
enum RecordScope {
    /// Main-conversation records of a session transcript.
    Primary,
    /// Records of one subagent transcript (`<session>/subagents/agent-<id>.jsonl`).
    Subagent,
}

/// True only for subagent transcripts: a `subagents` directory component and an `agent-*` file name.
pub(crate) fn is_subagent_transcript_path(path: &Path) -> bool {
    path.components().any(|component| {
        component
            .as_os_str()
            .to_string_lossy()
            .eq_ignore_ascii_case("subagents")
    }) && path
        .file_name()
        .and_then(|name| name.to_str())
        .is_some_and(|name| name.to_ascii_lowercase().starts_with("agent-"))
}

#[derive(Default)]
struct TurnState {
    /// Distinguishes this turn from later ones, so a response is only counted by its own turn.
    serial: u64,
    started_at: Option<DateTime<Utc>>,
    private_identity: String,
    session_identity: Option<String>,
    agent_identity: Option<String>,
    last_activity: Option<DateTime<Utc>>,
    invalid: bool,
    ambiguous: bool,
    incomplete_usage: bool,
    messages: HashMap<String, Option<i64>>,
    model: Option<String>,
    model_ambiguous: bool,
    has_modelless_message: bool,
    effort: Option<String>,
    effort_ambiguous: bool,
    provider: ProviderEvidence,
    /// The turn's terminal message. The turn is pending until the message's remaining records
    /// were read (see [`ClaudeTranscriptParser::flush_pending`]).
    terminal_message: Option<String>,
    /// The latest record of the terminal message ends with a thinking block: text still follows.
    terminal_thinking: bool,
    /// Bedrock inference-profile region evidence; only reported on the Bedrock route.
    region: ProviderEvidence,
    /// Qualifying API responses closed while this turn was active.
    responses: ResponseTotals,
    /// Id of the delegated work item reported as started for this subagent turn.
    work_id: Option<String>,
}

/// The API response (one unique `message.id`) whose records are currently being read.
struct OpenResponse {
    message_id: String,
    /// Latest user-type record before this response's first record.
    trigger: Option<DateTime<Utc>>,
    last_at: Option<DateTime<Utc>>,
    output_tokens: Option<i64>,
    /// Missing timestamps, shrinking usage or a synthetic message: never measured.
    unusable: bool,
    model: Option<String>,
    provider: Option<&'static str>,
    effort: Option<String>,
    session_identity: Option<String>,
    agent_identity: Option<String>,
    /// The turn that was active when the response began; only that turn counts it.
    turn_serial: Option<u64>,
    /// The latest record holds the message's final content block and its stop reason.
    complete: bool,
}

/// Provider evidence accumulated over the assistant messages of one turn.
#[derive(Clone, Copy, Default, Eq, PartialEq)]
enum ProviderEvidence {
    #[default]
    Unobserved,
    Single(&'static str),
    /// A message without evidence, or messages with different evidence.
    Unknown,
}

impl ProviderEvidence {
    fn observe(&mut self, evidence: Option<&'static str>) {
        *self = match (*self, evidence) {
            (_, None) | (Self::Unknown, _) => Self::Unknown,
            (Self::Unobserved, Some(provider)) => Self::Single(provider),
            (Self::Single(known), Some(provider)) if known == provider => Self::Single(known),
            (Self::Single(_), Some(_)) => Self::Unknown,
        };
    }

    fn provider(self) -> &'static str {
        match self {
            Self::Single(provider) => provider,
            Self::Unobserved | Self::Unknown => "unknown",
        }
    }
}

/// Reads Claude Code transcript records without retaining content blocks or prompts.
pub(crate) struct ClaudeTranscriptParser {
    scope: RecordScope,
    /// False when the reader began mid-file: prompts are ignored until a boundary is seen.
    synchronized: bool,
    source_identity: String,
    client_version: Option<String>,
    version_ambiguous: bool,
    turn: Option<TurnState>,
    emitted_ids: HashSet<String>,
    emitted_order: VecDeque<String>,
    /// Timestamp of the latest user-type record (prompt, tool result, notification, meta).
    latest_trigger: Option<DateTime<Utc>>,
    /// Timestamps of the last records seen, by `uuid`: a response starts at its parent record.
    record_times: HashMap<String, DateTime<Utc>>,
    record_order: VecDeque<String>,
    next_serial: u64,
    open_response: Option<OpenResponse>,
    closed_responses: HashSet<String>,
    closed_order: VecDeque<String>,
    responses: Vec<ResponseMetric>,
    delegation_events: Vec<DelegationEvent>,
}

impl ClaudeTranscriptParser {
    #[cfg(test)]
    pub fn new(source_identity: String) -> Self {
        Self::with_scope(source_identity, RecordScope::Primary)
    }

    #[cfg(test)]
    pub fn new_subagent(source_identity: String) -> Self {
        Self::with_scope(source_identity, RecordScope::Subagent)
    }

    /// Test helper: consumes a record and settles a pending terminal turn as a complete read would.
    #[cfg(test)]
    pub fn consume_settled(&mut self, line: &[u8]) -> Option<TurnMetric> {
        let closed = self.consume(line);
        closed.or_else(|| self.flush_pending(DateTime::<Utc>::MAX_UTC, true))
    }

    /// Chooses subagent or primary measurement from the transcript's location.
    pub fn for_path(path: &Path) -> Self {
        let scope = if is_subagent_transcript_path(path) {
            RecordScope::Subagent
        } else {
            RecordScope::Primary
        };
        Self::with_scope(String::new(), scope)
    }

    fn with_scope(source_identity: String, scope: RecordScope) -> Self {
        Self {
            scope,
            synchronized: true,
            source_identity,
            client_version: None,
            version_ambiguous: false,
            turn: None,
            emitted_ids: HashSet::new(),
            emitted_order: VecDeque::new(),
            latest_trigger: None,
            record_times: HashMap::new(),
            record_order: VecDeque::new(),
            next_serial: 0,
            open_response: None,
            closed_responses: HashSet::new(),
            closed_order: VecDeque::new(),
            responses: Vec::new(),
            delegation_events: Vec::new(),
        }
    }

    fn consume_value(&mut self, root: &Value) -> Option<TurnMetric> {
        let object = root.as_object()?;
        // Parents of responses can be records of any type or scope, so every record is noted.
        self.remember_record_time(object);
        if !self.accepts_record(object) {
            return None;
        }
        // A turn whose terminal message had only started (its thinking block) closes at the first
        // record that does not continue that message.
        let closed = self.close_unfinished_terminal(object);
        let produced = self.consume_record(object);
        closed.or(produced)
    }

    fn consume_record(&mut self, object: &serde_json::Map<String, Value>) -> Option<TurnMetric> {
        self.observe_version(object.get("version"));
        let record_type = object.get("type")?.as_str()?;
        let message = object.get("message").and_then(Value::as_object);
        match record_type {
            "user" => {
                // Any user-type record is the fallback trigger of the next request. It does not
                // end the response in flight: notifications can be written mid-response.
                if let Some(timestamp) = parse_date(object.get("timestamp")) {
                    self.latest_trigger = Some(timestamp);
                }
                if !message.is_some_and(|message| {
                    message.get("role").and_then(Value::as_str) == Some("user")
                }) {
                    return None;
                }
                // Subagent follow-up prompts arrive as meta records from the coordinator.
                let origin = object.get("origin").and_then(Value::as_object);
                let origin_kind = origin.map(|origin| origin.get("kind").and_then(Value::as_str));
                let coordinator_prompt =
                    self.scope == RecordScope::Subagent && origin_kind == Some(Some("coordinator"));
                // Meta records and records without a usable time are ignored entirely.
                if object.get("isMeta").and_then(Value::as_bool) == Some(true)
                    && !coordinator_prompt
                {
                    return None;
                }
                let timestamp = parse_date(object.get("timestamp"))?;
                let content = message.and_then(|message| message.get("content"));
                // Background events (task notifications and the like) are not prompts in either
                // scope; like tool output they are activity inside the turn. Only a human
                // origin, no origin, or a subagent's coordinator follow-up is a prompt.
                let background_event =
                    !coordinator_prompt && origin_kind.is_some_and(|kind| kind != Some("human"));
                if is_tool_result(content) || background_event {
                    if let Some(active) = self.turn.as_mut() {
                        record_activity(active, timestamp);
                    }
                    return None;
                }
                if is_interruption(content) {
                    // An interrupted turn has no trustworthy completion: drop it and
                    // do not treat the marker as the start of another turn.
                    self.drop_turn();
                    return None;
                }
                if !is_human_user(content) {
                    return None;
                }
                if !self.synchronized {
                    // Started mid-file: only a conversation's first prompt is a known boundary.
                    if object.get("parentUuid") != Some(&Value::Null) {
                        return None;
                    }
                    self.synchronized = true;
                }
                if let Some(active) = self.turn.as_mut() {
                    // The user typed while Claude was still working: the same turn
                    // continues from its original start unless activity stopped long ago.
                    if active.last_activity.is_some_and(|last| {
                        timestamp - last <= Duration::minutes(INTERJECTION_CONTINUATION_MINUTES)
                    }) {
                        record_activity(active, timestamp);
                        return None;
                    }
                }
                let identity = object
                    .get("uuid")
                    .or_else(|| message.and_then(|message| message.get("id")))
                    .and_then(Value::as_str)
                    .filter(|value| safe_identifier(value, MAX_IDENTIFIER_BYTES))
                    .map(str::to_owned)
                    .unwrap_or_else(|| timestamp.to_rfc3339());
                let session_identity = object
                    .get("sessionId")
                    .and_then(Value::as_str)
                    .filter(|value| safe_identifier(value, MAX_IDENTIFIER_BYTES))
                    .map(str::to_owned);
                let agent_identity = object
                    .get("agentId")
                    .and_then(Value::as_str)
                    .filter(|value| safe_identifier(value, MAX_IDENTIFIER_BYTES))
                    .map(str::to_owned);
                self.next_serial += 1;
                // A turn replaced by a new prompt was abandoned.
                self.drop_turn();
                let work_id = self.report_work_started(
                    session_identity.as_deref(),
                    agent_identity.as_deref(),
                    &identity,
                    timestamp,
                );
                self.turn = Some(TurnState {
                    serial: self.next_serial,
                    started_at: Some(timestamp),
                    last_activity: Some(timestamp),
                    private_identity: identity,
                    session_identity,
                    agent_identity,
                    work_id,
                    ..TurnState::default()
                });
                return None;
            }
            "assistant" => self.track_response(object, message),
            _ => return None,
        }

        if self.turn.is_none() {
            // A terminal assistant record is a turn boundary: the next prompt starts a whole turn.
            if !self.synchronized && message.is_some_and(|message| terminal(object, message)) {
                self.synchronized = true;
            }
            return None;
        }
        let Some(turn) = self.turn.as_mut() else {
            return None;
        };
        let Some(message) = message else {
            turn.ambiguous = true;
            return None;
        };
        if message.get("role").and_then(Value::as_str) != Some("assistant") {
            return None;
        }
        if let Some(timestamp) = parse_date(object.get("timestamp")) {
            record_activity(turn, timestamp);
        }
        let synthetic = message.get("model").and_then(Value::as_str) == Some(SYNTHETIC_MODEL);
        if synthetic {
            // Client-generated placeholder messages are not model output.
            turn.invalid = true;
        }
        if self.scope == RecordScope::Subagent
            && turn.agent_identity.as_deref()
                != object
                    .get("agentId")
                    .and_then(Value::as_str)
                    .filter(|value| safe_identifier(value, MAX_IDENTIFIER_BYTES))
        {
            turn.incomplete_usage = true;
        }
        if let (Some(original), Some(current)) = (
            turn.session_identity.as_deref(),
            object
                .get("sessionId")
                .and_then(Value::as_str)
                .filter(|value| safe_identifier(value, MAX_IDENTIFIER_BYTES)),
        ) {
            if original != current {
                turn.incomplete_usage = true;
            }
        }

        let message_id = message
            .get("id")
            .and_then(Value::as_str)
            .filter(|value| safe_identifier(value, MAX_IDENTIFIER_BYTES));
        let Some(message_id) = message_id else {
            turn.ambiguous = true;
            return terminal(object, message)
                .then(|| self.finish_turn(None))
                .flatten();
        };
        let usage = message.get("usage").and_then(Value::as_object);
        if !turn.messages.contains_key(message_id) && turn.messages.len() >= MAX_TRACKED_MESSAGES {
            turn.ambiguous = true;
        } else {
            let output_tokens = nonnegative_integer(usage.and_then(|u| u.get("output_tokens")));
            match turn.messages.get_mut(message_id) {
                Some(previous) => {
                    if let (Some(previous_value), Some(current_value)) = (*previous, output_tokens)
                    {
                        if current_value < previous_value {
                            turn.incomplete_usage = true;
                        } else {
                            // Output usage for one API message can be observed more than
                            // once while its transcript snapshot is being written. Keep
                            // the latest valid cumulative total; never add snapshots.
                            *previous = Some(current_value);
                        }
                    } else if previous.is_none() && output_tokens.is_some() {
                        *previous = output_tokens;
                    }
                }
                None => {
                    turn.messages.insert(message_id.to_owned(), output_tokens);
                }
            }
        }

        // A synthetic message only invalidates the turn; it never makes the model ambiguous.
        if !synthetic {
            // The provider comes only from explicit identifier evidence, never the model name.
            turn.provider.observe(provider_evidence(
                message_id,
                object.get("requestId").and_then(Value::as_str),
            ));
            turn.region.observe(Some(bedrock_region_or_unknown(
                message
                    .get("model")
                    .and_then(Value::as_str)
                    .and_then(bedrock_profile_region),
            )));
            if let Some(model) = message
                .get("model")
                .and_then(Value::as_str)
                .and_then(normalize_claude_model)
            {
                observe_model(&model, turn);
            } else {
                turn.has_modelless_message = true;
            }
        }
        observe_effort(object, message, turn);

        if terminal(object, message) {
            turn.terminal_message = Some(message_id.to_owned());
        }
        if turn.terminal_message.as_deref() == Some(message_id) {
            turn.terminal_thinking = ends_with_thinking(message);
        }
        // A terminal message may still receive records (its text after the thinking block), so
        // the turn stays pending and closes when something else arrives or the reader flushes.
        None
    }

    fn remember_record_time(&mut self, root: &serde_json::Map<String, Value>) {
        let (Some(uuid), Some(at)) = (
            root.get("uuid")
                .and_then(Value::as_str)
                .filter(|value| safe_identifier(value, MAX_IDENTIFIER_BYTES)),
            parse_date(root.get("timestamp")),
        ) else {
            return;
        };
        if self.record_times.insert(uuid.to_owned(), at).is_none() {
            self.record_order.push_back(uuid.to_owned());
            while self.record_order.len() > MAX_REMEMBERED_RECORDS {
                if let Some(oldest) = self.record_order.pop_front() {
                    self.record_times.remove(&oldest);
                }
            }
        }
    }

    /// The request that produced a response: the record named by its first record's
    /// `parentUuid` when it was seen and is not later than that record, else the latest
    /// user-type record.
    fn response_trigger(
        &self,
        root: &serde_json::Map<String, Value>,
        first_at: Option<DateTime<Utc>>,
    ) -> Option<DateTime<Utc>> {
        let parent = root
            .get("parentUuid")
            .and_then(Value::as_str)
            .and_then(|uuid| self.record_times.get(uuid))
            .copied();
        match (parent, first_at) {
            (Some(parent), Some(first)) if parent <= first => Some(parent),
            _ => self.latest_trigger,
        }
    }

    /// Finishes a turn pending on the rest of its terminal message.
    fn close_unfinished_terminal(
        &mut self,
        root: &serde_json::Map<String, Value>,
    ) -> Option<TurnMetric> {
        let pending = self.turn.as_ref()?.terminal_message.as_deref()?;
        let kind = root.get("type").and_then(Value::as_str);
        let message_id = root
            .get("message")
            .and_then(|message| message.get("id"))
            .and_then(Value::as_str);
        // The terminal message's own records and unrelated record types leave the turn pending;
        // a user-type record or another message ends it.
        let ends = match kind {
            Some("user") => true,
            Some("assistant") => message_id != Some(pending),
            _ => false,
        };
        if !ends {
            return None;
        }
        self.finish_unfinished_terminal()
    }

    fn finish_unfinished_terminal(&mut self) -> Option<TurnMetric> {
        self.close_response();
        let completed_at = self.turn.as_ref()?.last_activity;
        self.finish_turn(completed_at)
    }

    /// Follows the API response each assistant record belongs to. A response spans every record
    /// with its `message.id`; it ends with the last of them and starts at the latest user-type
    /// record before the first.
    fn track_response(
        &mut self,
        root: &serde_json::Map<String, Value>,
        message: Option<&serde_json::Map<String, Value>>,
    ) {
        let Some(message) = message
            .filter(|message| message.get("role").and_then(Value::as_str) == Some("assistant"))
        else {
            self.close_response();
            return;
        };
        let message_id = message
            .get("id")
            .and_then(Value::as_str)
            .filter(|value| safe_identifier(value, MAX_IDENTIFIER_BYTES));
        let Some(message_id) = message_id else {
            self.close_response();
            return;
        };
        let timestamp = parse_date(root.get("timestamp"));
        let tokens = nonnegative_integer(
            message
                .get("usage")
                .and_then(Value::as_object)
                .and_then(|usage| usage.get("output_tokens")),
        );
        let continues = self
            .open_response
            .as_ref()
            .is_some_and(|open| open.message_id == message_id);
        if !continues {
            self.close_response();
            if self.closed_responses.contains(message_id) {
                // Records of an already finished response resurfacing out of order.
                return;
            }
            let synthetic = message.get("model").and_then(Value::as_str) == Some(SYNTHETIC_MODEL);
            self.open_response = Some(OpenResponse {
                message_id: message_id.to_owned(),
                trigger: self.response_trigger(root, timestamp),
                last_at: None,
                output_tokens: None,
                unusable: synthetic,
                model: if synthetic {
                    None
                } else {
                    message
                        .get("model")
                        .and_then(Value::as_str)
                        .and_then(normalize_claude_model)
                },
                provider: provider_evidence(
                    message_id,
                    root.get("requestId").and_then(Value::as_str),
                ),
                effort: None,
                complete: false,
                turn_serial: self.turn.as_ref().map(|turn| turn.serial),
                session_identity: root
                    .get("sessionId")
                    .and_then(Value::as_str)
                    .filter(|value| safe_identifier(value, MAX_IDENTIFIER_BYTES))
                    .map(str::to_owned),
                agent_identity: root
                    .get("agentId")
                    .and_then(Value::as_str)
                    .filter(|value| safe_identifier(value, MAX_IDENTIFIER_BYTES))
                    .map(str::to_owned),
            });
        }
        let Some(open) = self.open_response.as_mut() else {
            return;
        };
        match timestamp {
            Some(timestamp) => {
                if open.last_at.map_or(true, |last| timestamp > last) {
                    open.last_at = Some(timestamp);
                }
            }
            None => open.unusable = true,
        }
        // Usage snapshots of one message only grow; a smaller later value is not trustworthy.
        match (open.output_tokens, tokens) {
            (Some(previous), Some(current)) if current < previous => open.unusable = true,
            (_, Some(current)) => open.output_tokens = Some(current),
            _ => {}
        }
        open.complete = message_is_complete(root, message);
        if open.effort.is_none() {
            open.effort = root
                .get("perTurnEffort")
                .or_else(|| root.get("effort"))
                .or_else(|| message.get("perTurnEffort"))
                .or_else(|| message.get("effort"))
                .and_then(Value::as_str)
                .filter(|value| ReportedReasoningEffort::is_allowed(value))
                .map(str::to_owned);
        }
    }

    /// Finishes the response in flight: counts it in the active turn and publishes it on the
    /// live list when it qualifies (200+ output tokens, 0 < duration <= 600 s, not synthetic).
    fn close_response(&mut self) {
        let Some(open) = self.open_response.take() else {
            return;
        };
        self.closed_order.push_back(open.message_id.clone());
        self.closed_responses.insert(open.message_id.clone());
        while self.closed_order.len() > MAX_CLOSED_RESPONSES {
            if let Some(oldest) = self.closed_order.pop_front() {
                self.closed_responses.remove(&oldest);
            }
        }
        if open.unusable {
            return;
        }
        let (Some(trigger), Some(end), Some(tokens)) =
            (open.trigger, open.last_at, open.output_tokens)
        else {
            return;
        };
        let Some(nanos) = (end - trigger).num_nanoseconds() else {
            return;
        };
        let duration = nanos as f64 / 1e9;
        if !response_qualifies(tokens, duration) {
            return;
        }
        if let Some(turn) = self
            .turn
            .as_mut()
            .filter(|turn| Some(turn.serial) == open.turn_serial)
        {
            turn.responses.add(tokens, duration);
        }
        if self.responses.len() >= MAX_PENDING_RESPONSES {
            self.responses.remove(0);
        }
        let identity = open
            .session_identity
            .as_deref()
            .unwrap_or(&self.source_identity);
        let id = match (self.scope, open.agent_identity.as_deref()) {
            (RecordScope::Subagent, Some(agent)) => {
                digest_id(&["response", identity, agent, &open.message_id])
            }
            _ => digest_id(&["response", identity, &open.message_id]),
        };
        self.responses.push(ResponseMetric {
            id,
            completed_at: end,
            model: open.model,
            provider: Some(open.provider.unwrap_or("unknown").to_owned()),
            client: CLAUDE_CLIENT.to_owned(),
            source_kind: Some(
                match self.scope {
                    RecordScope::Primary => "primary",
                    RecordScope::Subagent => "subagent",
                }
                .to_owned(),
            ),
            // Same metric version as the turns of this transcript scope.
            metric_version: match self.scope {
                RecordScope::Primary => CLAUDE_METRIC_VERSION,
                RecordScope::Subagent => CLAUDE_SUBAGENT_METRIC_VERSION,
            }
            .to_owned(),
            reasoning_effort: open.effort,
            output_tokens: tokens,
            duration_seconds: duration,
        });
    }

    fn accepts_record(&self, root: &serde_json::Map<String, Value>) -> bool {
        match self.scope {
            RecordScope::Primary => is_primary_record(root),
            RecordScope::Subagent => is_subagent_record(root),
        }
    }

    fn observe_version(&mut self, value: Option<&Value>) {
        let Some(value) = value.and_then(Value::as_str) else {
            return;
        };
        if !safe_version(value) {
            return;
        }
        if self
            .client_version
            .as_deref()
            .is_some_and(|known| known != value)
        {
            self.version_ambiguous = true;
            self.client_version = None;
        } else if !self.version_ambiguous {
            self.client_version = Some(value.to_owned());
        }
    }

    /// Settles the active turn: a measured turn is emitted (and reported as a primary turn or as
    /// finished delegated work), anything else is discarded.
    fn finish_turn(&mut self, completed_at: Option<DateTime<Utc>>) -> Option<TurnMetric> {
        let turn = self.turn.take()?;
        let work_id = turn.work_id.clone();
        let root_session = turn
            .session_identity
            .clone()
            .unwrap_or_else(|| self.source_identity.clone());
        let started_at = turn.started_at;
        let metric = self.measure_turn(turn, completed_at);
        match (&metric, work_id) {
            (Some(metric), Some(work_id)) => {
                self.delegation_events.push(DelegationEvent::Finished {
                    work_id,
                    output_tokens: metric.output_tokens,
                    finished_at: metric.completed_at,
                });
            }
            (None, Some(work_id)) => {
                self.delegation_events
                    .push(DelegationEvent::Discarded { work_id });
            }
            _ => {}
        }
        if let (RecordScope::Primary, Some(metric), Some(started_at)) =
            (self.scope, &metric, started_at)
        {
            self.delegation_events.push(DelegationEvent::Turn {
                turn_id: metric.id.clone(),
                root_session: root_session_key(CLAUDE_CLIENT, &root_session),
                started_at,
            });
        }
        metric
    }

    /// Abandons the active turn (interrupted, replaced or cut off by a mid-file start).
    fn drop_turn(&mut self) {
        if let Some(work_id) = self.turn.take().and_then(|turn| turn.work_id) {
            self.delegation_events
                .push(DelegationEvent::Discarded { work_id });
        }
    }

    /// Reports the start of a subagent turn as delegated work of the session it belongs to.
    /// Returns the work id, which is the id of the turn's metric.
    fn report_work_started(
        &mut self,
        session_identity: Option<&str>,
        agent_identity: Option<&str>,
        private_identity: &str,
        started_at: DateTime<Utc>,
    ) -> Option<String> {
        if self.scope != RecordScope::Subagent {
            return None;
        }
        let (Some(session), Some(agent)) = (session_identity, agent_identity) else {
            return None;
        };
        let work_id = digest_id(&[session, agent, private_identity]);
        self.delegation_events.push(DelegationEvent::Started {
            work_id: work_id.clone(),
            root_session: root_session_key(CLAUDE_CLIENT, session),
            started_at,
        });
        Some(work_id)
    }

    fn measure_turn(
        &mut self,
        turn: TurnState,
        completed_at: Option<DateTime<Utc>>,
    ) -> Option<TurnMetric> {
        let completed_at = completed_at?;
        let started_at = turn.started_at?;
        let duration = (completed_at - started_at).num_nanoseconds()? as f64 / 1e9;
        if turn.invalid
            || turn.ambiguous
            || turn.incomplete_usage
            || duration <= 0.0
            || !duration.is_finite()
            || turn.messages.is_empty()
            || turn.messages.values().any(Option::is_none)
        {
            return None;
        }
        let output_tokens = turn
            .messages
            .values()
            .try_fold(0_i64, |total, value| total.checked_add((*value)?))?;
        let throughput = output_tokens as f64 / duration;
        if !throughput.is_finite() || throughput < 0.0 {
            return None;
        }
        let (response_output_tokens, response_duration_seconds, response_count) =
            turn.responses.fields();
        let identity = turn
            .session_identity
            .as_deref()
            .unwrap_or(&self.source_identity);
        let id = match (self.scope, turn.agent_identity.as_deref()) {
            (RecordScope::Subagent, Some(agent)) => {
                digest_id(&[identity, agent, &turn.private_identity])
            }
            (RecordScope::Subagent, None) => return None,
            (RecordScope::Primary, _) => digest_id(&[identity, &turn.private_identity]),
        };
        if !self.remember_emitted(id.clone()) {
            return None;
        }
        Some(TurnMetric {
            id,
            completed_at,
            model: if turn.model_ambiguous || turn.has_modelless_message {
                None
            } else {
                turn.model
            },
            output_tokens,
            duration_seconds: duration,
            codex_ttft_seconds: None,
            turn_throughput_tps: throughput,
            streaming_tps: None,
            client_version: if self.version_ambiguous {
                None
            } else {
                self.client_version.clone()
            },
            client: CLAUDE_CLIENT.to_owned(),
            parser_version: CLAUDE_PARSER_VERSION.to_owned(),
            metric_version: match self.scope {
                RecordScope::Primary => CLAUDE_METRIC_VERSION,
                RecordScope::Subagent => CLAUDE_SUBAGENT_METRIC_VERSION,
            }
            .to_owned(),
            reasoning_output_tokens: None,
            source_kind: Some(
                match self.scope {
                    RecordScope::Primary => "primary",
                    RecordScope::Subagent => "subagent",
                }
                .to_owned(),
            ),
            provider: Some(turn.provider.provider().to_owned()),
            reasoning_effort: if turn.effort_ambiguous {
                None
            } else {
                turn.effort
            },
            response_output_tokens,
            response_duration_seconds,
            response_count,
            provider_region: (turn.provider.provider() == "amazon-bedrock")
                .then(|| turn.region.provider().to_owned()),
            delegated_output_tokens: None,
        })
    }

    fn remember_emitted(&mut self, id: String) -> bool {
        if !self.emitted_ids.insert(id.clone()) {
            return false;
        }
        self.emitted_order.push_back(id);
        while self.emitted_order.len() > MAX_EMITTED_TURNS {
            if let Some(oldest) = self.emitted_order.pop_front() {
                self.emitted_ids.remove(&oldest);
            }
        }
        true
    }
}

impl JsonlEventParser for ClaudeTranscriptParser {
    fn reset(&mut self, source_identity: String) {
        // Work this parser started will never be finished by it: settle it as discarded.
        self.drop_turn();
        let events = std::mem::take(&mut self.delegation_events);
        *self = Self::with_scope(source_identity, self.scope);
        self.delegation_events = events;
    }

    fn consume(&mut self, line: &[u8]) -> Option<TurnMetric> {
        if line.len() > super::reader::MAX_LINE_BYTES {
            return None;
        }
        let root: Value = serde_json::from_slice(line).ok()?;
        self.consume_value(&root)
    }

    fn excludes_session(&self) -> bool {
        false
    }

    fn begin_mid_file(&mut self) {
        // The header record was read, but the records between it and the tail were not, so
        // anything it started cannot be completed faithfully. The turn was never really seen, so
        // its work is withdrawn rather than discarded: a replay reader of the whole file reports
        // its true outcome.
        if let Some(work_id) = self.turn.take().and_then(|turn| turn.work_id) {
            self.delegation_events.retain(|event| {
                !matches!(event, DelegationEvent::Started { work_id: started, .. } if *started == work_id)
            });
        }
        self.synchronized = false;
        self.latest_trigger = None;
        self.record_times.clear();
        self.record_order.clear();
        self.open_response = None;
    }

    fn take_responses(&mut self) -> Vec<ResponseMetric> {
        std::mem::take(&mut self.responses)
    }

    fn take_delegation_events(&mut self) -> Vec<DelegationEvent> {
        std::mem::take(&mut self.delegation_events)
    }

    fn flush_pending(&mut self, now: DateTime<Utc>, final_read: bool) -> Option<TurnMetric> {
        if let Some(turn) = self
            .turn
            .as_ref()
            .filter(|turn| turn.terminal_message.is_some())
        {
            // A pending turn closes at the end of a read unless its message still ends in
            // thinking, and in any case once it has waited 30 s or the file is fully read.
            let waited = turn.last_activity.map_or(true, |last| {
                now - last >= Duration::seconds(PENDING_TURN_TIMEOUT_SECONDS)
            });
            return (final_read || !turn.terminal_thinking || waited)
                .then(|| self.finish_unfinished_terminal())
                .flatten();
        }
        if self
            .open_response
            .as_ref()
            .is_some_and(|open| open.complete || final_read)
        {
            self.close_response();
        }
        None
    }
}

fn terminal(
    root: &serde_json::Map<String, Value>,
    message: &serde_json::Map<String, Value>,
) -> bool {
    message
        .get("stop_reason")
        .or_else(|| root.get("stop_reason"))
        .and_then(Value::as_str)
        .is_some_and(|reason| matches!(reason, "end_turn" | "stop_sequence"))
}

fn content_blocks(message: &serde_json::Map<String, Value>) -> &[Value] {
    message
        .get("content")
        .and_then(Value::as_array)
        .map_or(&[], Vec::as_slice)
}

fn last_block_type(message: &serde_json::Map<String, Value>) -> Option<&str> {
    content_blocks(message)
        .last()
        .and_then(|block| block.get("type"))
        .and_then(Value::as_str)
}

/// A terminal record whose content stops at a thinking block: the text is a later record.
fn ends_with_thinking(message: &serde_json::Map<String, Value>) -> bool {
    matches!(
        last_block_type(message),
        Some("thinking" | "redacted_thinking")
    )
}

/// A record that carries the message's last content block (a tool call for `tool_use`, text
/// for the other stop reasons) and its stop reason: nothing more of the message follows.
fn message_is_complete(
    root: &serde_json::Map<String, Value>,
    message: &serde_json::Map<String, Value>,
) -> bool {
    let stop = message
        .get("stop_reason")
        .or_else(|| root.get("stop_reason"))
        .and_then(Value::as_str);
    match (stop, last_block_type(message)) {
        (Some("tool_use"), Some("tool_use")) => true,
        (Some(reason), Some("text")) => reason != "tool_use",
        _ => false,
    }
}

fn is_primary_record(root: &serde_json::Map<String, Value>) -> bool {
    root.get("isSidechain").and_then(Value::as_bool) == Some(false)
        && root.get("userType").and_then(Value::as_str) == Some("external")
        && !root.contains_key("agentId")
}

fn is_subagent_record(root: &serde_json::Map<String, Value>) -> bool {
    root.get("isSidechain").and_then(Value::as_bool) == Some(true)
        && root.get("userType").and_then(Value::as_str) == Some("external")
        && root
            .get("agentId")
            .and_then(Value::as_str)
            .is_some_and(|value| safe_identifier(value, MAX_IDENTIFIER_BYTES))
}

/// Claude Code records a user interruption as a text user record with this prefix.
fn is_interruption(content: Option<&Value>) -> bool {
    match content {
        Some(Value::String(text)) => text.starts_with(INTERRUPTION_MARKER),
        Some(Value::Array(blocks)) => blocks.iter().any(|block| {
            block.get("type").and_then(Value::as_str) == Some("text")
                && block
                    .get("text")
                    .and_then(Value::as_str)
                    .is_some_and(|text| text.starts_with(INTERRUPTION_MARKER))
        }),
        _ => false,
    }
}

fn record_activity(turn: &mut TurnState, timestamp: DateTime<Utc>) {
    if turn.last_activity.map_or(true, |last| timestamp > last) {
        turn.last_activity = Some(timestamp);
    }
}

fn is_tool_result(content: Option<&Value>) -> bool {
    matches!(content, Some(Value::Array(blocks)) if blocks.iter().any(|block| {
        block
            .get("type")
            .and_then(Value::as_str)
            .is_some_and(|kind| matches!(kind, "tool_result" | "tool_use_result"))
    }))
}

fn is_human_user(content: Option<&Value>) -> bool {
    match content {
        Some(Value::String(text)) => !text.is_empty(),
        Some(Value::Array(blocks)) => {
            !blocks.is_empty()
                && !blocks.iter().any(|block| {
                    block
                        .get("type")
                        .and_then(Value::as_str)
                        .is_some_and(|kind| matches!(kind, "tool_result" | "tool_use_result"))
                })
        }
        Some(Value::Object(_)) => true,
        _ => false,
    }
}

fn observe_model(model: &str, turn: &mut TurnState) {
    if turn.model.as_deref().is_some_and(|known| known != model) {
        turn.model = None;
        turn.model_ambiguous = true;
    } else if turn.model.is_none() && !turn.model_ambiguous {
        turn.model = Some(model.to_owned());
    }
}

const MAX_MODEL_BYTES: usize = 80;

/// Maps a transcript model value to the public Claude model name, or `None` when it is not a
/// safe identifier. Bedrock inference-profile ids and Vertex `@date` ids become the first-party
/// form so the same model compares equal across routes; ARNs and other unsafe values stay rejected.
pub(crate) fn normalize_claude_model(raw: &str) -> Option<String> {
    let normalized = bedrock_model(raw)
        .or_else(|| vertex_model(raw))
        .unwrap_or_else(|| raw.to_owned());
    safe_identifier(&normalized, MAX_MODEL_BYTES).then_some(normalized)
}

fn is_model_body(value: &str) -> bool {
    value
        .bytes()
        .all(|byte| matches!(byte, b'a'..=b'z' | b'0'..=b'9' | b'.' | b'-'))
}

fn is_digits(value: &str) -> bool {
    !value.is_empty() && value.bytes().all(|byte| byte.is_ascii_digit())
}

/// `^(?:[a-z]{2,6}(?:-[a-z]+)?\.)?anthropic\.(claude-[a-z0-9.-]+?)(?:-v[0-9]+(?::[0-9]+)?)?$`
fn bedrock_model(raw: &str) -> Option<String> {
    bedrock_parts(raw).map(|(model, _)| model)
}

/// The inference-profile prefix of a Bedrock model id (`us.anthropic.claude-...` gives `us`).
/// Prefixes that name no allowlisted region still match the id shape and are mapped by the caller.
pub(crate) fn bedrock_profile_region(raw: &str) -> Option<&str> {
    bedrock_parts_ref(raw).and_then(|(_, region)| region)
}

fn bedrock_parts(raw: &str) -> Option<(String, Option<&str>)> {
    bedrock_parts_ref(raw).map(|(model, region)| (model.to_owned(), region))
}

fn bedrock_parts_ref(raw: &str) -> Option<(&str, Option<&str>)> {
    let (region, rest) = match raw.strip_prefix("anthropic.") {
        Some(rest) => (None, rest),
        None => {
            let (region, rest) = raw.split_once('.')?;
            if !is_bedrock_region(region) {
                return None;
            }
            (Some(region), rest.strip_prefix("anthropic.")?)
        }
    };
    // The lazy group keeps at least one character after `claude-`, so an earlier "-v..."
    // belongs to the model name itself.
    let body = match rest.rfind("-v") {
        Some(index) if index > "claude-".len() && is_bedrock_version(&rest[index + 2..]) => {
            &rest[..index]
        }
        _ => rest,
    };
    (body.starts_with("claude-") && body.len() > "claude-".len() && is_model_body(body))
        .then_some((body, region))
}

/// `[a-z]{2,6}(?:-[a-z]+)?`
fn is_bedrock_region(value: &str) -> bool {
    let (head, tail) = match value.split_once('-') {
        Some((head, tail)) => (head, Some(tail)),
        None => (value, None),
    };
    let lower = |part: &str| !part.is_empty() && part.bytes().all(|byte| byte.is_ascii_lowercase());
    (2..=6).contains(&head.len()) && lower(head) && tail.map_or(true, lower)
}

/// `[0-9]+(?::[0-9]+)?`
fn is_bedrock_version(value: &str) -> bool {
    match value.split_once(':') {
        Some((major, minor)) => is_digits(major) && is_digits(minor),
        None => is_digits(value),
    }
}

/// `^(claude-[a-z0-9.-]+)@([0-9]{8})$` becomes `{1}-{2}`.
fn vertex_model(raw: &str) -> Option<String> {
    let (name, date) = raw.split_once('@')?;
    (name.starts_with("claude-")
        && name.len() > "claude-".len()
        && is_model_body(name)
        && date.len() == 8
        && is_digits(date))
    .then(|| format!("{name}-{date}"))
}

fn is_alphanumeric(value: &str) -> bool {
    value.bytes().all(|byte| byte.is_ascii_alphanumeric())
}

fn has_suffix_len(value: &str, prefix: &str, lengths: std::ops::RangeInclusive<usize>) -> bool {
    value
        .strip_prefix(prefix)
        .is_some_and(|suffix| lengths.contains(&suffix.len()) && is_alphanumeric(suffix))
}

/// Explicit provider evidence from API identifiers; `None` when the record establishes none.
/// Bedrock and Vertex mint their own message-id prefixes. A first-party id counts only with its
/// matching request id, so a bare `msg_01...` (also seen from proxies) is not evidence.
pub(crate) fn provider_evidence(
    message_id: &str,
    request_id: Option<&str>,
) -> Option<&'static str> {
    if has_suffix_len(message_id, "msg_bdrk_", 8..=64) {
        Some("amazon-bedrock")
    } else if has_suffix_len(message_id, "msg_vrtx_", 8..=64) {
        Some("google-vertex")
    } else if has_suffix_len(message_id, "msg_01", 22..=22)
        && request_id.is_some_and(|id| has_suffix_len(id, "req_", 20..=40))
    {
        Some("anthropic")
    } else {
        None
    }
}

fn observe_effort(
    root: &serde_json::Map<String, Value>,
    message: &serde_json::Map<String, Value>,
    turn: &mut TurnState,
) {
    let value = root
        .get("perTurnEffort")
        .or_else(|| root.get("effort"))
        .or_else(|| message.get("perTurnEffort"))
        .or_else(|| message.get("effort"));
    let Some(value) = value else {
        return;
    };
    let Some(value) = value.as_str() else {
        turn.effort = None;
        turn.effort_ambiguous = true;
        return;
    };
    if !ReportedReasoningEffort::is_allowed(value) {
        turn.effort = None;
        turn.effort_ambiguous = true;
        return;
    }
    if turn.effort.as_deref().is_some_and(|known| known != value) {
        turn.effort = None;
        turn.effort_ambiguous = true;
    } else if !turn.effort_ambiguous {
        turn.effort = Some(value.to_owned());
    }
}

fn parse_date(value: Option<&Value>) -> Option<DateTime<Utc>> {
    let value = value?.as_str()?;
    DateTime::parse_from_rfc3339(value)
        .ok()
        .map(|date| date.with_timezone(&Utc))
}

fn nonnegative_integer(value: Option<&Value>) -> Option<i64> {
    let value = value?.as_i64()?;
    (value >= 0).then_some(value)
}

fn safe_identifier(value: &str, maximum: usize) -> bool {
    !value.is_empty()
        && value.len() <= maximum
        && value
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'.' | b'_' | b'-'))
}

fn safe_version(value: &str) -> bool {
    !value.is_empty()
        && value.len() <= 40
        && value
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'.' | b'_' | b'-' | b'+'))
}

fn digest_id(parts: &[&str]) -> String {
    format!("{:x}", Sha256::digest(parts.join("|").as_bytes()))
}
