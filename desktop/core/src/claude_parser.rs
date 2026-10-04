use crate::model::{
    ReportedReasoningEffort, TurnMetric, CLAUDE_CLIENT, CLAUDE_METRIC_VERSION,
    CLAUDE_PARSER_VERSION,
};
use crate::parser::JsonlEventParser;
use chrono::{DateTime, Utc};
use serde_json::Value;
use sha2::{Digest, Sha256};
use std::collections::{HashMap, HashSet, VecDeque};

const MAX_TRACKED_MESSAGES: usize = 4_096;
const MAX_EMITTED_TURNS: usize = 8_192;
const MAX_IDENTIFIER_BYTES: usize = 512;

#[derive(Default)]
struct TurnState {
    started_at: Option<DateTime<Utc>>,
    private_identity: String,
    session_identity: Option<String>,
    ambiguous: bool,
    incomplete_usage: bool,
    messages: HashMap<String, Option<i64>>,
    model: Option<String>,
    model_ambiguous: bool,
    has_modelless_message: bool,
    effort: Option<String>,
    effort_ambiguous: bool,
}

/// Reads Claude Code transcript records without retaining content blocks or prompts.
pub(crate) struct ClaudeTranscriptParser {
    source_identity: String,
    client_version: Option<String>,
    version_ambiguous: bool,
    turn: Option<TurnState>,
    next_ordinal: u64,
    emitted_ids: HashSet<String>,
    emitted_order: VecDeque<String>,
}

impl ClaudeTranscriptParser {
    pub fn new(source_identity: String) -> Self {
        Self {
            source_identity,
            client_version: None,
            version_ambiguous: false,
            turn: None,
            next_ordinal: 0,
            emitted_ids: HashSet::new(),
            emitted_order: VecDeque::new(),
        }
    }

    fn consume_value(&mut self, root: &Value) -> Option<TurnMetric> {
        let object = root.as_object()?;
        if object.get("isSidechain").and_then(Value::as_bool) == Some(true) {
            return None;
        }
        if !is_primary_record(object) {
            return None;
        }
        self.observe_version(object.get("version"));
        let record_type = object.get("type")?.as_str()?;
        let message = object.get("message").and_then(Value::as_object);
        match record_type {
            "user" => {
                if !message.is_some_and(|message| {
                    message.get("role").and_then(Value::as_str) == Some("user")
                }) || !is_human_user(message.and_then(|message| message.get("content")))
                {
                    return None;
                }
                let timestamp = parse_date(object.get("timestamp"));
                if let Some(active) = self.turn.as_mut() {
                    // A human message inside an unfinished assistant/tool cycle makes
                    // the transcript boundary ambiguous, so fail this turn closed.
                    active.ambiguous = true;
                    return None;
                }
                let identity = object
                    .get("uuid")
                    .or_else(|| message.and_then(|message| message.get("id")))
                    .and_then(Value::as_str)
                    .filter(|value| safe_identifier(value, MAX_IDENTIFIER_BYTES))
                    .map(str::to_owned)
                    .or_else(|| timestamp.map(|date| date.to_rfc3339()))
                    .unwrap_or_else(|| {
                        self.next_ordinal = self.next_ordinal.saturating_add(1);
                        format!("missing-time-{}", self.next_ordinal)
                    });
                let session_identity = object
                    .get("sessionId")
                    .and_then(Value::as_str)
                    .filter(|value| safe_identifier(value, MAX_IDENTIFIER_BYTES))
                    .map(str::to_owned);
                self.turn = Some(TurnState {
                    started_at: timestamp,
                    private_identity: identity,
                    session_identity,
                    ..TurnState::default()
                });
                return None;
            }
            "assistant" => {}
            _ => return None,
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

        if message
            .get("model")
            .and_then(Value::as_str)
            .is_some_and(|model| safe_identifier(model, 80))
        {
            observe_model(message.get("model").and_then(Value::as_str), turn);
        } else {
            turn.has_modelless_message = true;
        }
        observe_effort(object, message, turn);

        if terminal(object, message) {
            let completed_at = parse_date(object.get("timestamp"));
            self.finish_turn(completed_at)
        } else {
            None
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
        if turn.ambiguous
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
        let id = digest_id(identity, &turn.private_identity);
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
            metric_version: CLAUDE_METRIC_VERSION.to_owned(),
            reasoning_output_tokens: None,
            source_kind: Some("primary".to_owned()),
            // A product/model name does not establish which provider route was used.
            provider: Some("unknown".to_owned()),
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
        *self = Self::new(source_identity);
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

fn observe_model(model: Option<&str>, turn: &mut TurnState) {
    let Some(model) = model.filter(|value| safe_identifier(value, 80)) else {
        return;
    };
    if turn.model.as_deref().is_some_and(|known| known != model) {
        turn.model = None;
        turn.model_ambiguous = true;
    } else if turn.model.is_none() && !turn.model_ambiguous {
        turn.model = Some(model.to_owned());
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

fn digest_id(source: &str, turn: &str) -> String {
    let mut digest = Sha256::new();
    digest.update(source.as_bytes());
    digest.update(b"|");
    digest.update(turn.as_bytes());
    format!("{:x}", digest.finalize())
}
