//! Kimi Code wire logs (metrics contract "Kimi Code (0.1.21)"): the append-only `wire.jsonl` of one
//! agent of a session, read for turns, live responses and delegated work.
//!
//! The format is not a public API, so every field is optional and anything malformed or missing
//! makes the parser skip the record. Prompts, content, tool data and error messages are never read.

use crate::delegation::{root_session_key, DelegationEvent};
use crate::model::{
    push_outcomes, request_outcome_key, response_qualifies, speed_is_plausible,
    ReportedReasoningEffort, RequestOutcome, RequestOutcomeKind, ResponseMetric, ResponseTotals,
    ToolSurface, TurnMetric, KIMI_CLIENT, KIMI_METRIC_VERSION, KIMI_PARSER_VERSION,
};
use crate::parser::JsonlEventParser;
use chrono::{DateTime, Utc};
use serde_json::{Map, Value};
use sha2::{Digest, Sha256};
use std::path::Path;

const MAX_IDENTIFIER_BYTES: usize = 512;
const MAX_MODEL_BYTES: usize = 80;
/// The largest token count a step may report; a larger one is a corrupt record.
const MAX_USAGE_TOKENS: i64 = 100_000_000;
/// Completed responses wait here until the reader drains them after each poll.
const MAX_PENDING_RESPONSES: usize = 1_024;
const WIRE_FILE: &str = "wire.jsonl";
const MAIN_AGENT: &str = "main";
/// The desktop app's chat-title generation sessions: ignored completely.
const TITLE_SESSION_PREFIX: &str = "ctitle-";
/// `turn.ended` reasons that discard the turn.
const FAILED_TURN_REASONS: [&str; 5] = ["failed", "aborted", "cancelled", "interrupted", "error"];

/// Which agent's log a parser instance reads.
#[derive(Clone, Copy, Eq, PartialEq)]
enum Scope {
    /// `agents/main/wire.jsonl`: measured as turns and live responses.
    Main,
    /// Any other agent folder: read only for delegated work.
    Subagent,
}

/// True for `sessions/<workspace>/<session>/agents/<agent>/wire.jsonl` (relative to a Kimi Code
/// home) of a session that is not a title session; `subagent` selects the agent folders other than
/// `main` instead of `main`.
pub(crate) fn is_wire_path(relative: &Path, subagent: bool) -> bool {
    let parts: Vec<_> = relative
        .components()
        .map(|component| component.as_os_str().to_string_lossy())
        .collect();
    matches!(
        parts.as_slice(),
        [sessions, _, session, agents, agent, file]
            if sessions == "sessions"
                && !session.starts_with(TITLE_SESSION_PREFIX)
                && agents == "agents"
                && (agent == MAIN_AGENT) != subagent
                && file == WIRE_FILE
    )
}

/// True when a folder (relative to a Kimi Code home) can hold a wire log, so a walk of the home does
/// not descend into its other folders (logs, plugins, caches) or into title sessions.
pub(crate) fn can_hold_wire(relative_dir: &Path) -> bool {
    let parts: Vec<_> = relative_dir
        .components()
        .map(|component| component.as_os_str().to_string_lossy())
        .collect();
    parts.len() <= 5
        && parts.iter().enumerate().all(|(index, part)| match index {
            0 => part == "sessions",
            2 => !part.starts_with(TITLE_SESSION_PREFIX),
            3 => part == "agents",
            _ => true,
        })
}

/// The latest `turn.prompt` since the previous turn began.
struct Prompt {
    at_ms: i64,
    /// A user prompt, or any prompt in a subagent log.
    counts: bool,
}

/// The `llm.request` that a step's call was made with.
struct Request {
    at_ms: i64,
    model: Option<String>,
    provider: &'static str,
    effort: Option<String>,
}

/// The model and provider of the `llm.request` a step's call was made with, kept after the step
/// ended: a `turn.ended` failure is attributed to them.
#[derive(Clone)]
struct StepRequest {
    model: Option<String>,
    provider: &'static str,
}

/// A step between its `step.begin` and its `step.end`.
struct OpenStep {
    step: u64,
    /// The latest request written for it (a retried call writes another).
    request: Option<Request>,
}

/// What a value is across the steps of a turn: one value, or no agreed one.
enum Common<T> {
    Unobserved,
    Single(T),
    Mixed,
}

impl<T: PartialEq> Common<T> {
    fn observe(&mut self, value: Option<T>) {
        *self = match (std::mem::replace(self, Self::Mixed), value) {
            (_, None) | (Self::Mixed, _) => Self::Mixed,
            (Self::Unobserved, Some(value)) => Self::Single(value),
            (Self::Single(known), Some(value)) if known == value => Self::Single(known),
            (Self::Single(_), Some(_)) => Self::Mixed,
        };
    }

    fn get(&self) -> Option<&T> {
        match self {
            Self::Single(value) => Some(value),
            Self::Unobserved | Self::Mixed => None,
        }
    }
}

struct TurnState {
    id: String,
    /// The prompt's time when the turn counts (a counted prompt and a first step observed from the
    /// start); `None` for a turn that belongs to no measured turn.
    started_ms: Option<i64>,
    /// Id of the delegated work item reported as started (subagent logs).
    work_id: Option<String>,
    /// The turn reached its first successful `end_turn` (and was emitted when it counts). Steps
    /// that follow belong to no measured turn and only feed the live response stream.
    completed: bool,
    /// A step failed or has no request, or the turn was ended without an answer.
    failed: bool,
    open: Option<OpenStep>,
    /// The request of the latest step, cleared when a step begins.
    step_request: Option<StepRequest>,
    output_tokens: i64,
    input_tokens: i64,
    cache_read_tokens: i64,
    responses: ResponseTotals,
    model: Common<String>,
    provider: Common<&'static str>,
    effort: Common<String>,
}

impl TurnState {
    fn new(id: String, started_ms: Option<i64>) -> Self {
        Self {
            id,
            started_ms,
            work_id: None,
            completed: false,
            failed: false,
            open: None,
            step_request: None,
            output_tokens: 0,
            input_tokens: 0,
            cache_read_tokens: 0,
            responses: ResponseTotals::default(),
            model: Common::Unobserved,
            provider: Common::Unobserved,
            effort: Common::Unobserved,
        }
    }
}

/// The four counts of a `step.end` `usage`.
struct Usage {
    input_other: i64,
    output: i64,
    input_cache_read: i64,
    input_cache_creation: i64,
}

impl Usage {
    /// All four counts present, non-negative integers of at most 100,000,000.
    fn parse(value: Option<&Value>) -> Option<Self> {
        let usage = value?.as_object()?;
        let count = |name: &str| {
            usage
                .get(name)
                .and_then(Value::as_i64)
                .filter(|count| (0..=MAX_USAGE_TOKENS).contains(count))
        };
        Some(Self {
            input_other: count("inputOther")?,
            output: count("output")?,
            input_cache_read: count("inputCacheRead")?,
            input_cache_creation: count("inputCacheCreation")?,
        })
    }
}

/// Reads one agent's Kimi Code wire log without retaining anything but numbers and digests.
pub(crate) struct KimiWireParser {
    scope: Scope,
    surface: Option<ToolSurface>,
    /// Name of the session folder: the root session of delegated work and part of every digest.
    session: String,
    /// Name of the agent folder.
    agent: String,
    latest_prompt: Option<Prompt>,
    turn: Option<TurnState>,
    responses: Vec<ResponseMetric>,
    delegation_events: Vec<DelegationEvent>,
    outcomes: Vec<RequestOutcome>,
}

impl KimiWireParser {
    /// A parser for the agent of `path` (`.../<session>/agents/<agent>/wire.jsonl`) under a home
    /// of the given surface.
    pub fn for_path(path: &Path, surface: Option<ToolSurface>) -> Self {
        let name = |path: Option<&Path>| {
            path.and_then(Path::file_name)
                .map(|name| name.to_string_lossy().into_owned())
                .unwrap_or_default()
        };
        let agent_dir = path.parent();
        let session = name(agent_dir.and_then(Path::parent).and_then(Path::parent));
        Self::new(session, name(agent_dir), surface)
    }

    pub fn new(session: String, agent: String, surface: Option<ToolSurface>) -> Self {
        Self {
            scope: if agent == MAIN_AGENT {
                Scope::Main
            } else {
                Scope::Subagent
            },
            surface,
            session,
            agent,
            latest_prompt: None,
            turn: None,
            responses: Vec::new(),
            delegation_events: Vec::new(),
            outcomes: Vec::new(),
        }
    }

    fn consume_value(&mut self, root: &Value) -> Option<TurnMetric> {
        let root = root.as_object()?;
        // A record without a finite integer time is ignored.
        let at_ms = root.get("time")?.as_i64()?;
        match root.get("type")?.as_str()? {
            "turn.prompt" => self.latest_prompt = Some(self.prompt(root, at_ms)),
            "llm.request" => self.observe_request(root, at_ms),
            "context.append_loop_event" => return self.consume_loop_event(root, at_ms),
            "turn.step.interrupted" => self.end_turn_early(root, None),
            "turn.ended" => {
                self.observe_turn_error(root, at_ms);
                self.end_turn_early(root, Some(("reason", &FAILED_TURN_REASONS)))
            }
            "agent.turn.ended" => {
                self.end_turn_early(root, Some(("outcome", &["failed", "aborted"])))
            }
            "prompt.aborted" => self.fail_turn(),
            _ => {}
        }
        None
    }

    fn prompt(&self, root: &Map<String, Value>, at_ms: i64) -> Prompt {
        Prompt {
            at_ms,
            counts: self.scope == Scope::Subagent || is_user_prompt(root.get("origin")),
        }
    }

    fn consume_loop_event(&mut self, root: &Map<String, Value>, at_ms: i64) -> Option<TurnMetric> {
        let event = root.get("event")?.as_object()?;
        let kind = event.get("type")?.as_str()?;
        if !matches!(kind, "step.begin" | "step.end") {
            return None;
        }
        let turn_id = identifier(event.get("turnId"))?;
        let step = event.get("step")?.as_u64().filter(|step| *step >= 1)?;
        if kind == "step.begin" {
            self.begin_step(turn_id, step);
            None
        } else {
            self.end_step(event, &turn_id, step, at_ms)
        }
    }

    /// A step began. A turn id that is not the current turn's ends that turn: one that has not
    /// completed was left unfinished and is discarded.
    fn begin_step(&mut self, turn_id: String, step: u64) {
        if self.turn.as_ref().is_some_and(|turn| turn.id != turn_id) {
            self.drop_turn();
        }
        if self.turn.is_none() {
            self.start_turn(turn_id, step);
            return;
        }
        // A step that never ended while another began cannot have succeeded.
        if self.turn.as_ref().is_some_and(|turn| turn.open.is_some()) {
            self.fail_turn();
        }
        if let Some(turn) = self.turn.as_mut() {
            turn.step_request = None;
            turn.open = Some(OpenStep {
                step,
                request: None,
            });
        }
    }

    /// A step.begin of a turn id not seen as the current one: it counts when the latest prompt does
    /// and its first step is observed. Starting a turn clears the remembered prompt.
    fn start_turn(&mut self, turn_id: String, step: u64) {
        let prompt = self.latest_prompt.take();
        let started_ms = prompt
            .filter(|prompt| prompt.counts && step == 1)
            .map(|prompt| prompt.at_ms);
        let mut turn = TurnState::new(turn_id, started_ms);
        if let (Scope::Subagent, Some(started_ms)) = (self.scope, started_ms) {
            let work_id = digest_id(&[
                "subagent",
                KIMI_CLIENT,
                &self.session,
                &self.agent,
                &turn.id,
                &started_ms.to_string(),
            ]);
            if let Some(started_at) = DateTime::<Utc>::from_timestamp_millis(started_ms) {
                self.delegation_events.push(DelegationEvent::Started {
                    work_id: work_id.clone(),
                    root_session: root_session_key(KIMI_CLIENT, &self.session),
                    started_at,
                });
                turn.work_id = Some(work_id);
            }
        }
        turn.open = Some(OpenStep {
            step,
            request: None,
        });
        self.turn = Some(turn);
    }

    fn observe_request(&mut self, root: &Map<String, Value>, at_ms: i64) {
        let Some(turn) = self.turn.as_mut() else {
            return;
        };
        let Some(open) = turn.open.as_mut() else {
            return;
        };
        if root.get("turnStep").and_then(Value::as_str)
            != Some(&format!("{}.{}", turn.id, open.step))
        {
            return;
        }
        let text = |name: &str| root.get(name).and_then(Value::as_str);
        let model = text("model")
            .filter(|model| safe_model(model))
            .map(str::to_owned);
        // Kimi Code's provider type for Moonshot's own API; any other is a third-party service.
        let provider = if text("provider") == Some("kimi") {
            "moonshot"
        } else {
            "unknown"
        };
        turn.step_request = Some(StepRequest {
            model: model.clone(),
            provider,
        });
        open.request = Some(Request {
            at_ms,
            model,
            provider,
            effort: text("thinkingEffort")
                .filter(|effort| ReportedReasoningEffort::is_allowed(effort))
                .map(str::to_owned),
        });
    }

    /// A `turn.ended` that carries an error is one failed request when the error is a
    /// provider-side one: `provider.overloaded`, or `provider.api_error` with a 5xx status. The
    /// other records of the failed turn (`step.end`, `turn.step.interrupted`, `agent.turn.ended`)
    /// and the retries before it are not counted. Only the error's code and status are read.
    fn observe_turn_error(&mut self, root: &Map<String, Value>, at_ms: i64) {
        let (Some(error), Some(turn_id)) = (
            root.get("error").and_then(Value::as_object),
            identifier(root.get("turnId")),
        ) else {
            return;
        };
        let Some(kind) = classify_turn_error(error) else {
            return;
        };
        // The failure belongs to the request of the current turn's latest step.
        let Some(request) = self
            .turn
            .as_ref()
            .filter(|turn| turn.id == turn_id)
            .and_then(|turn| turn.step_request.clone())
        else {
            return;
        };
        self.push_outcome(
            request_outcome_key(&[
                KIMI_CLIENT,
                "turn-error",
                &self.session,
                &self.agent,
                &turn_id,
                &at_ms.to_string(),
            ]),
            at_ms,
            request.model.as_deref(),
            request.provider,
            kind,
        );
    }

    fn push_outcome(
        &mut self,
        dedupe_key: String,
        at_ms: i64,
        model: Option<&str>,
        provider: &str,
        kind: RequestOutcomeKind,
    ) {
        let Some(occurred_at) = DateTime::<Utc>::from_timestamp_millis(at_ms) else {
            return;
        };
        if let Some(outcome) = RequestOutcome::new(
            dedupe_key,
            occurred_at,
            KIMI_CLIENT,
            None,
            KIMI_PARSER_VERSION,
            model,
            Some(provider),
            kind,
        ) {
            push_outcomes(&mut self.outcomes, vec![outcome]);
        }
    }

    /// A step ended. The first successful `end_turn` of a turn whose steps all succeeded completes
    /// it, and the turn is returned.
    fn end_step(
        &mut self,
        event: &Map<String, Value>,
        turn_id: &str,
        step: u64,
        at_ms: i64,
    ) -> Option<TurnMetric> {
        let turn = self.turn.as_mut().filter(|turn| turn.id == turn_id)?;
        if turn.open.as_ref().map(|open| open.step) != Some(step) {
            return None;
        }
        let request = turn.open.take().and_then(|open| open.request);
        let finish = event.get("finishReason").and_then(Value::as_str);
        let (Some(request), Some(usage), true) = (
            request,
            Usage::parse(event.get("usage")),
            matches!(finish, Some("tool_use" | "end_turn")),
        ) else {
            self.fail_turn();
            return None;
        };
        // A successful step is one succeeded request, whatever its length.
        self.push_outcome(
            request_outcome_key(&[
                KIMI_CLIENT,
                "step",
                &self.session,
                &self.agent,
                turn_id,
                &step.to_string(),
                &at_ms.to_string(),
            ]),
            at_ms,
            request.model.as_deref(),
            request.provider,
            RequestOutcomeKind::Succeeded,
        );
        let Some(turn) = self.turn.as_mut().filter(|turn| turn.id == turn_id) else {
            return None;
        };
        let duration = (at_ms - request.at_ms) as f64 / 1_000.0;
        let qualifies = response_qualifies(usage.output, duration);
        if turn.completed {
            if qualifies && self.scope == Scope::Main {
                self.publish_response(&request, turn_id, step, at_ms, usage.output, duration);
            }
            return None;
        }
        turn.output_tokens = turn.output_tokens.saturating_add(usage.output);
        turn.input_tokens = turn
            .input_tokens
            .saturating_add(usage.input_other)
            .saturating_add(usage.input_cache_read)
            .saturating_add(usage.input_cache_creation);
        turn.cache_read_tokens = turn
            .cache_read_tokens
            .saturating_add(usage.input_cache_read);
        turn.model.observe(request.model.clone());
        turn.provider.observe(Some(request.provider));
        turn.effort.observe(request.effort.clone());
        if qualifies {
            turn.responses.add(usage.output, duration);
        }
        let completes = finish == Some("end_turn") && !turn.failed;
        if qualifies && self.scope == Scope::Main {
            self.publish_response(&request, turn_id, step, at_ms, usage.output, duration);
        }
        completes.then(|| self.complete(at_ms)).flatten()
    }

    /// One successful, qualifying step is one live response, whichever turn it belongs to.
    fn publish_response(
        &mut self,
        request: &Request,
        turn_id: &str,
        step: u64,
        at_ms: i64,
        output_tokens: i64,
        duration_seconds: f64,
    ) {
        let Some(completed_at) = DateTime::<Utc>::from_timestamp_millis(at_ms) else {
            return;
        };
        if self.responses.len() >= MAX_PENDING_RESPONSES {
            self.responses.remove(0);
        }
        self.responses.push(ResponseMetric {
            id: digest_id(&[
                "response",
                KIMI_CLIENT,
                &self.session,
                turn_id,
                &step.to_string(),
                &at_ms.to_string(),
            ]),
            completed_at,
            model: request.model.clone(),
            provider: Some(request.provider.to_owned()),
            client: KIMI_CLIENT.to_owned(),
            source_kind: Some("primary".to_owned()),
            metric_version: KIMI_METRIC_VERSION.to_owned(),
            reasoning_effort: request.effort.clone(),
            output_tokens,
            duration_seconds,
        });
    }

    /// A record that ends the current turn without an answer: `turn.step.interrupted`, or a
    /// `turn.ended` / `agent.turn.ended` whose `field` holds one of the `failing` values (`None`
    /// fails on the record alone). Only the current turn's id counts.
    fn end_turn_early(&mut self, root: &Map<String, Value>, failing: Option<(&str, &[&str])>) {
        let ends = failing.is_none_or(|(field, values)| {
            root.get(field)
                .and_then(Value::as_str)
                .is_some_and(|value| values.contains(&value))
        });
        let current = identifier(root.get("turnId"));
        if ends
            && current.is_some()
            && current.as_deref() == self.turn.as_ref().map(|turn| turn.id.as_str())
        {
            self.fail_turn();
        }
    }

    /// Discards the current turn unless it completed already: a failure after the answer does not
    /// affect what was emitted.
    fn fail_turn(&mut self) {
        if let Some(turn) = self.turn.as_mut().filter(|turn| !turn.completed) {
            turn.failed = true;
            self.discard_work();
        }
    }

    /// Reports the work item of the current turn as discarded, once.
    fn discard_work(&mut self) {
        if let Some(work_id) = self.turn.as_mut().and_then(|turn| turn.work_id.take()) {
            self.delegation_events
                .push(DelegationEvent::Discarded { work_id });
        }
    }

    /// Forgets the current turn; work it started and did not finish is discarded.
    fn drop_turn(&mut self) {
        self.discard_work();
        self.turn = None;
    }

    /// Completes the current turn at `completed_ms`: a measured main turn becomes a record, a
    /// subagent turn finishes its work item. A turn that cannot be measured is discarded.
    fn complete(&mut self, completed_ms: i64) -> Option<TurnMetric> {
        let measured = self.measure(completed_ms);
        let turn = self.turn.as_mut()?;
        turn.completed = true;
        let Some((started_at, completed_at, duration)) = measured else {
            self.discard_work();
            return None;
        };
        if self.scope == Scope::Subagent {
            if let Some(work_id) = turn.work_id.take() {
                self.delegation_events.push(DelegationEvent::Finished {
                    work_id,
                    output_tokens: turn.output_tokens,
                    finished_at: completed_at,
                });
            }
            return None;
        }
        let id = digest_id(&[
            KIMI_CLIENT,
            &self.session,
            &turn.id,
            &started_at.timestamp_millis().to_string(),
        ]);
        let mut metric = TurnMetric::new_observed(
            id.clone(),
            completed_at,
            turn.model.get().cloned(),
            turn.output_tokens,
            duration,
            None,
            None,
            Some("primary".to_owned()),
            Some(turn.provider.get().copied().unwrap_or("unknown").to_owned()),
            turn.effort.get().cloned(),
            KIMI_CLIENT,
            KIMI_PARSER_VERSION,
            KIMI_METRIC_VERSION,
        );
        (
            metric.response_output_tokens,
            metric.response_duration_seconds,
            metric.response_count,
        ) = turn.responses.fields();
        metric.surface = self.surface;
        // Kimi Code reports no cache writes: its `inputCacheCreation` is always 0.
        metric.set_prompt_cache(Some(turn.input_tokens), Some(turn.cache_read_tokens), None);
        self.delegation_events.push(DelegationEvent::Turn {
            turn_id: id,
            root_session: root_session_key(KIMI_CLIENT, &self.session),
            started_at,
        });
        Some(metric)
    }

    /// Start, completion and positive duration of the current turn, when it counts and its speed is
    /// possible.
    fn measure(&self, completed_ms: i64) -> Option<(DateTime<Utc>, DateTime<Utc>, f64)> {
        let turn = self.turn.as_ref()?;
        let started_ms = turn.started_ms?;
        let duration = completed_ms.checked_sub(started_ms)? as f64 / 1_000.0;
        if !speed_is_plausible(turn.output_tokens, duration) {
            return None;
        }
        Some((
            DateTime::<Utc>::from_timestamp_millis(started_ms)?,
            DateTime::<Utc>::from_timestamp_millis(completed_ms)?,
            duration,
        ))
    }
}

impl JsonlEventParser for KimiWireParser {
    fn reset(&mut self, _source_identity: String) {
        // Work this parser started will never be finished by it: settle it as discarded.
        self.drop_turn();
        self.latest_prompt = None;
        self.responses.clear();
    }

    fn consume(&mut self, line: &[u8]) -> Option<TurnMetric> {
        if line.len() > crate::reader::MAX_LINE_BYTES {
            return None;
        }
        let root: Value = serde_json::from_slice(line).ok()?;
        self.consume_value(&root)
    }

    fn excludes_session(&self) -> bool {
        false
    }

    fn begin_mid_file(&mut self) {
        // The records between the header and the tail were never seen: whatever the header
        // started is not a turn this parser can measure.
        self.drop_turn();
        self.latest_prompt = None;
    }

    fn take_responses(&mut self) -> Vec<ResponseMetric> {
        std::mem::take(&mut self.responses)
    }

    fn take_delegation_events(&mut self) -> Vec<DelegationEvent> {
        std::mem::take(&mut self.delegation_events)
    }

    fn take_outcomes(&mut self) -> Vec<RequestOutcome> {
        std::mem::take(&mut self.outcomes)
    }
}

/// The provider-side failure a `turn.ended` error stands for: `provider.overloaded`, or
/// `provider.api_error` whose `details.statusCode` is a 5xx. Rate limits, sign-in problems,
/// connection errors and every other code are the user's side and `None`.
fn classify_turn_error(error: &Map<String, Value>) -> Option<RequestOutcomeKind> {
    match error.get("code").and_then(Value::as_str)? {
        "provider.overloaded" => Some(RequestOutcomeKind::Overloaded),
        "provider.api_error" => error
            .get("details")
            .and_then(Value::as_object)
            .and_then(|details| details.get("statusCode"))
            .and_then(Value::as_i64)
            .and_then(RequestOutcomeKind::from_http_status),
        _ => None,
    }
}

/// A user prompt: no origin, kind `user`, or a slash command the user typed.
fn is_user_prompt(origin: Option<&Value>) -> bool {
    let Some(origin) = origin else {
        return true;
    };
    let Some(origin) = origin.as_object() else {
        return false;
    };
    match origin.get("kind").and_then(Value::as_str) {
        Some("user") => true,
        Some("skill_activation" | "plugin_command") => {
            origin.get("trigger").and_then(Value::as_str) == Some("user-slash")
        }
        _ => false,
    }
}

/// A turn id: a string, or the integer that some records carry instead; nothing else.
fn identifier(value: Option<&Value>) -> Option<String> {
    match value? {
        Value::String(text) if !text.is_empty() && text.len() <= MAX_IDENTIFIER_BYTES => {
            Some(text.clone())
        }
        Value::Number(number) => number
            .as_u64()
            .map(|number| number.to_string())
            .or_else(|| number.as_i64().map(|number| number.to_string())),
        _ => None,
    }
}

fn safe_model(value: &str) -> bool {
    !value.is_empty()
        && value.len() <= MAX_MODEL_BYTES
        && value
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'.' | b'_' | b'-'))
}

fn digest_id(parts: &[&str]) -> String {
    format!("{:x}", Sha256::digest(parts.join("|").as_bytes()))
}
