use crate::model::{
    ReportedReasoningEffort, TurnMetric, CLAUDE_CLIENT, CLAUDE_METRIC_VERSION,
    CLAUDE_PARSER_VERSION, CLAUDE_SUBAGENT_METRIC_VERSION,
};
use crate::parser::JsonlEventParser;
use chrono::{DateTime, Duration, Utc};
use serde_json::Value;
use sha2::{Digest, Sha256};
use std::collections::{HashMap, HashSet, VecDeque};
use std::path::Path;

const MAX_TRACKED_MESSAGES: usize = 4_096;
const MAX_EMITTED_TURNS: usize = 8_192;
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
        }
    }

    fn consume_value(&mut self, root: &Value) -> Option<TurnMetric> {
        let object = root.as_object()?;
        if !self.accepts_record(object) {
            return None;
        }
        self.observe_version(object.get("version"));
        let record_type = object.get("type")?.as_str()?;
        let message = object.get("message").and_then(Value::as_object);
        match record_type {
            "user" => {
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
                    self.turn = None;
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
                self.turn = Some(TurnState {
                    started_at: Some(timestamp),
                    last_activity: Some(timestamp),
                    private_identity: identity,
                    session_identity,
                    agent_identity,
                    ..TurnState::default()
                });
                return None;
            }
            "assistant" => {}
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
            let completed_at = parse_date(object.get("timestamp"));
            self.finish_turn(completed_at)
        } else {
            None
        }
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

    fn finish_turn(&mut self, completed_at: Option<DateTime<Utc>>) -> Option<TurnMetric> {
        let turn = self.turn.take()?;
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
        *self = Self::with_scope(source_identity, self.scope);
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
        // anything it started cannot be completed faithfully.
        self.turn = None;
        self.synchronized = false;
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
    let rest = match raw.strip_prefix("anthropic.") {
        Some(rest) => rest,
        None => {
            let (region, rest) = raw.split_once('.')?;
            if !is_bedrock_region(region) {
                return None;
            }
            rest.strip_prefix("anthropic.")?
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
        .then(|| body.to_owned())
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
