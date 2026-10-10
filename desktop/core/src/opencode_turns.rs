//! The in-memory index of OpenCode sessions and messages, and the turns and live responses built
//! from it (metrics contract "OpenCode").

use crate::model::{
    request_outcome_key, response_qualifies, speed_is_plausible, ReportedReasoningEffort,
    RequestOutcome, RequestOutcomeKind, ResponseMetric, ResponseTotals, TurnMetric,
    OPENCODE_CLIENT, OPENCODE_METRIC_VERSION, OPENCODE_PARSER_VERSION,
};
use crate::opencode_db::{Assistant, MessageKind, Read, SessionRow};
use chrono::{DateTime, Utc};
use sha2::{Digest, Sha256};
use std::collections::{HashMap, HashSet};

/// Sessions below this `major.minor` are not measured: before 1.14 the split of `tokens.output`
/// and `tokens.reasoning` is unverified.
const VERSION_FLOOR: (u32, u32) = (1, 14);
/// A primary turn stops waiting for unfinished delegated work this long after it ended.
pub(crate) const DELEGATION_MAX_WAIT_MS: i64 = 30 * 60 * 1_000;
const MAX_SESSION_DEPTH: usize = 16;
const MAX_SESSION_VERSION_BYTES: usize = 40;
const MAX_PROVIDER_BYTES: usize = 40;
/// A last message ending in one of these is a call in flight, not an answer.
const FINISH_NOT_TERMINAL: [&str; 2] = ["tool-calls", "unknown"];

struct Session {
    parent_id: Option<String>,
    version: String,
    /// `major.minor` is at or above [`VERSION_FLOOR`].
    measured: bool,
    messages: HashMap<String, Message>,
}

struct Message {
    updated_ms: i64,
    kind: MessageKind,
}

impl Message {
    fn created_ms(&self) -> i64 {
        match &self.kind {
            MessageKind::User { created_ms } => *created_ms,
            MessageKind::Assistant(assistant) => assistant.created_ms,
        }
    }
}

/// One turn read from the index and whether its delegated output is final.
pub(crate) struct EvaluatedTurn {
    pub metric: TurnMetric,
    /// `delegated_output_tokens` is `Some` in `metric`.
    pub delegated_final: bool,
}

/// What a merge changed.
#[derive(Default)]
pub(crate) struct Merged {
    /// Primary sessions whose turns may have changed.
    pub dirty_sessions: HashSet<String>,
    /// Assistant messages that were new or changed, for live responses.
    pub assistants: Vec<(String, String)>,
}

/// Messages of the last seven days grouped by session, plus the session tree.
#[derive(Default)]
pub(crate) struct Index {
    sessions: HashMap<String, Session>,
    children: HashMap<String, Vec<String>>,
    /// The largest `time_updated` seen (milliseconds).
    pub watermark: i64,
}

impl Index {
    pub fn clear(&mut self) {
        *self = Self::default();
    }

    pub fn has_session(&self, id: &str) -> bool {
        self.sessions.contains_key(id)
    }

    fn insert_session(&mut self, row: SessionRow) {
        let measured = version_is_measured(&row.version);
        let version = if row.version.len() <= MAX_SESSION_VERSION_BYTES {
            row.version
        } else {
            String::new()
        };
        if let Some(existing) = self.sessions.get_mut(&row.id) {
            existing.parent_id = row.parent_id.clone();
            existing.version = version;
            existing.measured = measured;
        } else {
            self.sessions.insert(
                row.id.clone(),
                Session {
                    parent_id: row.parent_id.clone(),
                    version,
                    measured,
                    messages: HashMap::new(),
                },
            );
        }
        if let Some(parent) = row.parent_id {
            let siblings = self.children.entry(parent).or_default();
            if !siblings.contains(&row.id) {
                siblings.push(row.id);
            }
        }
    }

    /// Merges a read into the index and reports which primary sessions need evaluating again.
    pub fn merge(&mut self, read: Read, retention_start_ms: i64) -> Merged {
        for session in read.sessions {
            self.insert_session(session);
        }
        let mut merged = Merged::default();
        for message in read.messages {
            self.watermark = self.watermark.max(message.updated_ms);
            let Some(session) = self.sessions.get_mut(&message.session_id) else {
                continue;
            };
            let entry = Message {
                updated_ms: message.updated_ms,
                kind: message.kind,
            };
            if entry.created_ms() < retention_start_ms {
                continue;
            }
            let is_assistant = matches!(entry.kind, MessageKind::Assistant(_));
            let changed = session
                .messages
                .get(&message.id)
                .is_none_or(|old| old.updated_ms != entry.updated_ms || old.kind != entry.kind);
            session.messages.insert(message.id.clone(), entry);
            if !changed {
                continue;
            }
            if is_assistant {
                merged
                    .assistants
                    .push((message.session_id.clone(), message.id.clone()));
            }
            if let Some(root) = self.root_of(&message.session_id) {
                merged.dirty_sessions.insert(root);
            }
        }
        merged
    }

    /// Forgets messages created before the retention start and sessions left without any.
    pub fn prune(&mut self, retention_start_ms: i64) {
        for session in self.sessions.values_mut() {
            session
                .messages
                .retain(|_, message| message.created_ms() >= retention_start_ms);
        }
    }

    /// The primary session a session belongs to: itself, or the top of its `parent_id` chain.
    pub fn root_of(&self, session_id: &str) -> Option<String> {
        let mut current = session_id;
        for _ in 0..MAX_SESSION_DEPTH {
            let session = self.sessions.get(current)?;
            match session.parent_id.as_deref() {
                None => return Some(current.to_owned()),
                Some(parent) => current = parent,
            }
        }
        None
    }

    /// Every primary session that holds a message.
    pub fn primary_sessions(&self) -> Vec<String> {
        self.sessions
            .iter()
            .filter(|(_, session)| session.parent_id.is_none() && !session.messages.is_empty())
            .map(|(id, _)| id.clone())
            .collect()
    }

    /// The assistant message, when it belongs to a measured primary session.
    pub fn primary_assistant(&self, session_id: &str, message_id: &str) -> Option<&Assistant> {
        let session = self.sessions.get(session_id)?;
        if session.parent_id.is_some() || !session.measured {
            return None;
        }
        match &session.messages.get(message_id)?.kind {
            MessageKind::Assistant(assistant) => Some(&**assistant),
            MessageKind::User { .. } => None,
        }
    }

    /// The assistant message and its session's OpenCode version, when it belongs to a measured
    /// session, primary or subagent: every model call is a request, whoever made it.
    pub fn measured_assistant(
        &self,
        session_id: &str,
        message_id: &str,
    ) -> Option<(&str, &Assistant)> {
        let session = self
            .sessions
            .get(session_id)
            .filter(|session| session.measured)?;
        match &session.messages.get(message_id)?.kind {
            MessageKind::Assistant(assistant) => Some((session.version.as_str(), &**assistant)),
            MessageKind::User { .. } => None,
        }
    }

    /// Assistant messages of the sessions descending from a primary session, which are the
    /// delegated (subagent) work of its turns.
    fn delegated_messages(&self, root: &str) -> Vec<&Assistant> {
        let mut found = Vec::new();
        let mut visited: HashSet<&str> = HashSet::new();
        let mut pending: Vec<(&str, usize)> = vec![(root, 0)];
        while let Some((id, depth)) = pending.pop() {
            if depth >= MAX_SESSION_DEPTH {
                continue;
            }
            for child in self.children.get(id).into_iter().flatten() {
                if !visited.insert(child.as_str()) {
                    continue;
                }
                if let Some(session) = self.sessions.get(child) {
                    if session.measured {
                        found.extend(session.messages.values().filter_map(|message| {
                            match &message.kind {
                                MessageKind::Assistant(assistant) => Some(&**assistant),
                                MessageKind::User { .. } => None,
                            }
                        }));
                    }
                }
                pending.push((child.as_str(), depth + 1));
            }
        }
        found
    }

    /// The measurable turns of one primary session, each with its delegated output attributed
    /// as far as the index allows at `now`.
    pub fn evaluate(&self, session_id: &str, now: DateTime<Utc>) -> Vec<EvaluatedTurn> {
        let Some(session) = self.sessions.get(session_id) else {
            return Vec::new();
        };
        if session.parent_id.is_some() || !session.measured {
            return Vec::new();
        }
        let mut answers: HashMap<&str, Vec<(&str, &Assistant)>> = HashMap::new();
        for (id, message) in &session.messages {
            if let MessageKind::Assistant(assistant) = &message.kind {
                if let Some(parent) = assistant.parent_id.as_deref() {
                    answers.entry(parent).or_default().push((id, assistant));
                }
            }
        }
        let delegated = self.delegated_messages(session_id);
        let mut turns = Vec::new();
        for (id, message) in &session.messages {
            let MessageKind::User { created_ms } = message.kind else {
                continue;
            };
            let Some(assistants) = answers.get(id.as_str()) else {
                continue;
            };
            if let Some(turn) = build_turn(
                session_id,
                &session.version,
                id,
                created_ms,
                assistants,
                &delegated,
                now,
            ) {
                turns.push(turn);
            }
        }
        turns
    }
}

/// `major.minor[.patch]` with `major.minor` at or above 1.14.
pub(crate) fn version_is_measured(version: &str) -> bool {
    let mut parts = version.split('.');
    let (Some(major), Some(minor)) = (parts.next(), parts.next()) else {
        return false;
    };
    let patch_ok = match parts.next() {
        None => true,
        Some(patch) => patch
            .bytes()
            .next()
            .is_some_and(|byte| byte.is_ascii_digit()),
    };
    let (Ok(major), Ok(minor)) = (major.parse::<u32>(), minor.parse::<u32>()) else {
        return false;
    };
    patch_ok && parts.next().is_none() && (major, minor) >= VERSION_FLOOR
}

/// The provider as shown and stored locally: the four shared providers by name, any other plain id
/// as it is (so the user sees where it ran), anything else unknown.
pub(crate) fn map_provider(provider: Option<&str>) -> String {
    let Some(provider) = provider else {
        return "unknown".to_owned();
    };
    let plain = provider.len() <= MAX_PROVIDER_BYTES
        && provider
            .bytes()
            .next()
            .is_some_and(|byte| byte.is_ascii_lowercase() || byte.is_ascii_digit())
        && provider.bytes().all(|byte| {
            byte.is_ascii_lowercase() || byte.is_ascii_digit() || matches!(byte, b'.' | b'_' | b'-')
        });
    if plain {
        provider.to_owned()
    } else {
        "unknown".to_owned()
    }
}

fn effort_of(variant: Option<&str>) -> Option<String> {
    variant
        .filter(|value| ReportedReasoningEffort::is_allowed(value))
        .map(str::to_owned)
}

fn time(ms: i64) -> Option<DateTime<Utc>> {
    DateTime::from_timestamp_millis(ms)
}

fn seconds(start_ms: i64, end_ms: i64) -> f64 {
    (end_ms - start_ms) as f64 / 1_000.0
}

/// The value every item agrees on; `None` when any is missing or they differ.
fn common<T: PartialEq + Clone>(values: impl Iterator<Item = Option<T>>) -> Option<T> {
    let mut values = values;
    let first = values.next()??;
    values
        .all(|value| value.as_ref() == Some(&first))
        .then_some(first)
}

fn digest(parts: &[&str]) -> String {
    format!("{:x}", Sha256::digest(parts.join("|").as_bytes()))
}

/// SHA-256 hex of `opencode|<sessionId>|<userMessageId>`.
pub(crate) fn turn_id(session_id: &str, user_message_id: &str) -> String {
    digest(&[OPENCODE_CLIENT, session_id, user_message_id])
}

/// Local digest only used to deduplicate live responses.
pub(crate) fn response_id(message_id: &str) -> String {
    digest(&[OPENCODE_CLIENT, "response", message_id])
}

fn build_turn(
    session_id: &str,
    session_version: &str,
    user_message_id: &str,
    started_ms: i64,
    assistants: &[(&str, &Assistant)],
    delegated: &[&Assistant],
    now: DateTime<Utc>,
) -> Option<EvaluatedTurn> {
    if assistants
        .iter()
        .any(|(_, assistant)| assistant.malformed || assistant.failed)
    {
        return None;
    }
    let mut ordered: Vec<&(&str, &Assistant)> = assistants.iter().collect();
    ordered.sort_by(|left, right| {
        left.1
            .created_ms
            .cmp(&right.1.created_ms)
            .then_with(|| left.0.cmp(right.0))
    });
    // A message still running, or a last one that is not a terminal answer (a tool call in
    // flight, or the empty finish-less message OpenCode leaves when the user interrupts).
    let completions: Option<Vec<i64>> = ordered
        .iter()
        .map(|(_, assistant)| assistant.completed_ms)
        .collect();
    let completed_ms = completions?.into_iter().max()?;
    let last = ordered.last()?.1;
    if last
        .finish
        .as_deref()
        .is_none_or(|finish| FINISH_NOT_TERMINAL.contains(&finish))
    {
        return None;
    }
    let duration = seconds(started_ms, completed_ms);
    let output_tokens = assistants.iter().fold(0i64, |sum, (_, assistant)| {
        sum.saturating_add(assistant.output_tokens)
    });
    let reasoning_tokens = assistants.iter().fold(0i64, |sum, (_, assistant)| {
        sum.saturating_add(assistant.reasoning_tokens)
    });
    if duration <= 0.0 || !speed_is_plausible(output_tokens, duration) {
        return None;
    }

    let model = common(
        assistants
            .iter()
            .map(|(_, assistant)| assistant.model.clone()),
    );
    let provider = common(
        assistants
            .iter()
            .map(|(_, assistant)| Some(map_provider(assistant.provider.as_deref()))),
    )
    .unwrap_or_else(|| "unknown".to_owned());
    let effort = common(
        assistants
            .iter()
            .map(|(_, assistant)| effort_of(assistant.variant.as_deref())),
    );

    let mut responses = ResponseTotals::default();
    for (_, assistant) in assistants {
        if let Some(end) = assistant.completed_ms {
            let span = seconds(assistant.created_ms, end);
            if response_qualifies(assistant.output_tokens, span) {
                responses.add(assistant.output_tokens, span);
            }
        }
    }
    let (response_output_tokens, response_duration_seconds, response_count) = responses.fields();

    // Delegated output: subagent messages that started during the turn.
    let (delegated_total, delegated_final) =
        delegated_output(delegated, started_ms, completed_ms, now);

    let client_version = (!session_version.is_empty()).then(|| session_version.to_owned());
    let mut metric = TurnMetric::new_observed(
        turn_id(session_id, user_message_id),
        time(completed_ms)?,
        model,
        output_tokens,
        duration,
        client_version,
        Some(reasoning_tokens),
        Some("primary".to_owned()),
        Some(provider.clone()),
        effort,
        OPENCODE_CLIENT,
        OPENCODE_PARSER_VERSION,
        OPENCODE_METRIC_VERSION,
    );
    metric.response_output_tokens = response_output_tokens;
    metric.response_duration_seconds = response_duration_seconds;
    metric.response_count = response_count;
    metric.delegated_output_tokens = delegated_final.then_some(delegated_total);
    prompt_cache(&mut metric, assistants, &provider);
    Some(EvaluatedTurn {
        metric,
        delegated_final,
    })
}

/// `tokens.input` excludes cached tokens, so the total adds all three counts. Only Anthropic
/// reports cache writes; elsewhere a logged 0 is not a report.
fn prompt_cache(metric: &mut TurnMetric, assistants: &[(&str, &Assistant)], provider: &str) {
    let mut input = Some(0i64);
    let mut read = Some(0i64);
    let mut write = 0i64;
    for (_, assistant) in assistants {
        let (Some(message_input), Some(message_read)) =
            (assistant.input_tokens, assistant.cache_read_tokens)
        else {
            metric.set_prompt_cache(None, None, None);
            return;
        };
        let message_write = assistant.cache_write_tokens.unwrap_or(0);
        input = input.map(|sum| {
            sum.saturating_add(message_input)
                .saturating_add(message_read)
                .saturating_add(message_write)
        });
        read = read.map(|sum| sum.saturating_add(message_read));
        write = write.saturating_add(message_write);
    }
    metric.set_prompt_cache(input, read, (provider == "anthropic").then_some(write));
}

/// Σ output of subagent messages created within the turn, and whether that total is final: every
/// such message finished (or failed), or the wait after the turn ended ran out, when unfinished
/// ones are ignored.
fn delegated_output(
    messages: &[&Assistant],
    started_ms: i64,
    completed_ms: i64,
    now: DateTime<Utc>,
) -> (i64, bool) {
    let mut total = 0i64;
    let mut unfinished = false;
    for message in messages {
        if message.created_ms < started_ms || message.created_ms > completed_ms {
            continue;
        }
        if message.malformed || (message.completed_ms.is_none() && !message.failed) {
            unfinished = true;
            continue;
        }
        total = total.saturating_add(message.output_tokens);
    }
    let waited_out = now.timestamp_millis() >= completed_ms.saturating_add(DELEGATION_MAX_WAIT_MS);
    (total, !unfinished || waited_out)
}

/// A live response for one assistant message, when it qualifies and completed after `since`.
pub(crate) fn live_response(
    message_id: &str,
    assistant: &Assistant,
    since: DateTime<Utc>,
) -> Option<ResponseMetric> {
    if assistant.malformed || assistant.failed {
        return None;
    }
    let completed_ms = assistant.completed_ms?;
    let completed_at = time(completed_ms)?;
    let span = seconds(assistant.created_ms, completed_ms);
    if completed_at <= since || !response_qualifies(assistant.output_tokens, span) {
        return None;
    }
    Some(ResponseMetric {
        id: response_id(message_id),
        completed_at,
        model: Some(assistant.model.clone()?),
        provider: Some(map_provider(assistant.provider.as_deref())),
        client: OPENCODE_CLIENT.to_owned(),
        source_kind: Some("primary".to_owned()),
        metric_version: OPENCODE_METRIC_VERSION.to_owned(),
        reasoning_effort: effort_of(assistant.variant.as_deref()),
        output_tokens: assistant.output_tokens,
        duration_seconds: span,
    })
}

/// The request outcome of one assistant message (one model call) that finished after `since`: a
/// completed message without an error succeeded; an `APIError` with a 5xx status is a failure
/// (529 an overload); every other error (aborted, auth, context, 4xx, no status) is not counted.
/// Only the error's name and status were read from the database, never its message. A message
/// without a model, or on a provider that maps to `unknown`, takes no part.
pub(crate) fn request_outcome(
    message_id: &str,
    session_version: &str,
    assistant: &Assistant,
    since: DateTime<Utc>,
) -> Option<RequestOutcome> {
    if assistant.malformed {
        return None;
    }
    let (kind, at_ms) = if assistant.failed {
        if !assistant.api_error {
            return None;
        }
        let kind = RequestOutcomeKind::from_http_status(assistant.error_status?)?;
        (kind, assistant.completed_ms.unwrap_or(assistant.created_ms))
    } else {
        (RequestOutcomeKind::Succeeded, assistant.completed_ms?)
    };
    let occurred_at = time(at_ms).filter(|at| *at > since)?;
    let provider = map_provider(assistant.provider.as_deref());
    RequestOutcome::new(
        request_outcome_key(&[OPENCODE_CLIENT, "message", message_id]),
        occurred_at,
        OPENCODE_CLIENT,
        (!session_version.is_empty()).then(|| session_version.to_owned()),
        OPENCODE_PARSER_VERSION,
        assistant.model.as_deref(),
        Some(&provider),
        kind,
    )
}
