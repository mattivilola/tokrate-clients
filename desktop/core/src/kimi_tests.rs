//! Tests for the Kimi Code adapter: the sanitized real logs in `tests/fixtures/kimi` and synthetic
//! logs for every rule of the metrics contract "Kimi Code (0.1.21)".

use crate::delegation::{root_session_key, DelegationEvent};
use crate::kimi::{can_hold_wire, is_wire_path, KimiWireParser};
use crate::parser::JsonlEventParser;
use crate::reader::IncrementalReader;
use crate::{
    Monitor, ProviderBadge, ResponseMetric, SharedSample, SourceChange, SourceCheckpoints,
    SourceMonitor, ToolSurface, TurnMetric, KIMI_CLIENT, KIMI_METRIC_VERSION, KIMI_PARSER_VERSION,
};
use chrono::{DateTime, Duration, Utc};
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::fs;
use std::path::{Path, PathBuf};
use std::time::SystemTime;
use tempfile::TempDir;
use uuid::Uuid;

const SESSION: &str = "conv-test";
const FIXTURES: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fixtures/kimi");
/// The `time` of the first record of every synthetic log.
const T0: i64 = 1_790_000_000_000;

// --- records -----------------------------------------------------------------------------------

fn prompt(at: i64, origin: Option<Value>) -> Value {
    let mut record = json!({"type": "turn.prompt", "time": at});
    if let Some(origin) = origin {
        record["origin"] = origin;
    }
    record
}

fn begin(at: i64, turn: &str, step: u64) -> Value {
    json!({"type": "context.append_loop_event", "time": at,
        "event": {"type": "step.begin", "turnId": turn, "step": step}})
}

fn request(at: i64, turn: &str, step: u64, model: &str, provider: &str, effort: &str) -> Value {
    json!({"type": "llm.request", "time": at, "kind": "loop", "provider": provider,
        "model": model, "thinkingEffort": effort, "turnStep": format!("{turn}.{step}")})
}

fn usage(input_other: i64, output: i64, cache_read: i64) -> Value {
    json!({"inputOther": input_other, "output": output, "inputCacheRead": cache_read,
        "inputCacheCreation": 0})
}

fn end_with(at: i64, turn: &str, step: u64, finish: Option<&str>, usage: Option<Value>) -> Value {
    let mut event = json!({"type": "step.end", "turnId": turn, "step": step});
    if let Some(finish) = finish {
        event["finishReason"] = json!(finish);
    }
    if let Some(usage) = usage {
        event["usage"] = usage;
    }
    json!({"type": "context.append_loop_event", "time": at, "event": event})
}

fn end(at: i64, turn: &str, step: u64, finish: &str, output: i64) -> Value {
    end_with(at, turn, step, Some(finish), Some(usage(100, output, 50)))
}

/// One step: begin one millisecond after `at`, request one more, and the end `seconds` later.
fn step(at: i64, turn: &str, step: u64, finish: &str, output: i64, seconds: i64) -> Vec<Value> {
    vec![
        begin(at + 1, turn, step),
        request(at + 2, turn, step, "k2d8-preview", "kimi", "high"),
        end(at + 2 + seconds * 1_000, turn, step, finish, output),
    ]
}

/// A user prompt and one step that answers it: `output` tokens in `seconds`.
fn answer(at: i64, turn: &str, output: i64, seconds: i64) -> Vec<Value> {
    let mut records = vec![prompt(at, None)];
    records.extend(step(at, turn, 1, "end_turn", output, seconds));
    records
}

fn at_ms(ms: i64) -> DateTime<Utc> {
    DateTime::from_timestamp_millis(ms).unwrap()
}

fn lines(records: &[Value]) -> Vec<u8> {
    let mut bytes = Vec::new();
    for record in records {
        bytes.extend_from_slice(record.to_string().as_bytes());
        bytes.push(b'\n');
    }
    bytes
}

// --- parser harness ----------------------------------------------------------------------------

fn main_parser() -> KimiWireParser {
    KimiWireParser::new(SESSION.into(), "main".into(), Some(ToolSurface::Cli))
}

fn subagent_parser() -> KimiWireParser {
    KimiWireParser::new(SESSION.into(), "sub-1".into(), Some(ToolSurface::Cli))
}

/// Feeds the records and returns the turns they complete. A turn completes at its first
/// `end_turn`, so a reader's position in the file never changes what it measures.
fn feed(parser: &mut KimiWireParser, records: &[Value]) -> Vec<TurnMetric> {
    records
        .iter()
        .filter_map(|record| parser.consume(record.to_string().as_bytes()))
        .collect()
}

fn turns_of(records: &[Value]) -> Vec<TurnMetric> {
    feed(&mut main_parser(), records)
}

fn the_turn(records: &[Value]) -> TurnMetric {
    let mut turns = turns_of(records);
    assert_eq!(turns.len(), 1, "one turn expected");
    turns.remove(0)
}

fn digest(parts: &[&str]) -> String {
    format!("{:x}", Sha256::digest(parts.join("|").as_bytes()))
}

// --- real logs through the monitors ------------------------------------------------------------

fn fixture(name: &str) -> Vec<u8> {
    fs::read(Path::new(FIXTURES).join(name)).unwrap()
}

fn set_modified(path: &Path, at: DateTime<Utc>) {
    fs::OpenOptions::new()
        .write(true)
        .open(path)
        .unwrap()
        .set_modified(SystemTime::from(at))
        .unwrap();
}

/// A Kimi Code home with one log at `sessions/wd_x/<session>/agents/<agent>/wire.jsonl`.
struct Home {
    dir: TempDir,
}

impl Home {
    fn new() -> Self {
        Self {
            dir: TempDir::new().unwrap(),
        }
    }

    fn root(&self) -> PathBuf {
        self.dir.path().join("home")
    }

    fn wire(&self, session: &str, agent: &str) -> PathBuf {
        self.root()
            .join("sessions/wd_x")
            .join(session)
            .join("agents")
            .join(agent)
            .join("wire.jsonl")
    }

    fn write(&self, session: &str, agent: &str, bytes: &[u8], modified: DateTime<Utc>) -> PathBuf {
        let path = self.wire(session, agent);
        fs::create_dir_all(path.parent().unwrap()).unwrap();
        fs::write(&path, bytes).unwrap();
        set_modified(&path, modified);
        path
    }

    fn empty(&self, name: &str) -> PathBuf {
        let path = self.dir.path().join(name);
        fs::create_dir_all(&path).unwrap();
        path
    }

    /// A monitor reading this home as the command line's (`desktop` false) or the app's.
    fn monitor(&self, desktop: bool) -> SourceMonitor {
        let (cli, app) = if desktop {
            (self.empty("no-cli"), self.root())
        } else {
            (self.root(), self.empty("no-app"))
        };
        SourceMonitor::new(
            self.empty("codex"),
            self.empty("claude"),
            self.empty("grok"),
            self.empty("gemini"),
            self.empty("opencode"),
            cli,
            app,
        )
    }
}

struct Polled {
    turns: Vec<TurnMetric>,
    live: Vec<ResponseMetric>,
}

/// Polls repeatedly at `now` until the monitor has nothing left to read.
fn poll(monitor: &mut SourceMonitor, now: DateTime<Utc>) -> Polled {
    let mut polled = Polled {
        turns: Vec::new(),
        live: Vec::new(),
    };
    for _ in 0..6 {
        polled.turns.extend(monitor.poll(now).unwrap());
        polled.live.extend(monitor.take_live_responses());
    }
    polled
}

#[test]
fn the_real_desktop_log_of_two_steps_is_one_turn_with_one_response() {
    let home = Home::new();
    let completed = at_ms(1_791_543_260_330);
    home.write(
        "conv-22ebc177fa959871b7c04a95",
        "main",
        &fixture("desktop-k2d8-two-step-success.jsonl"),
        completed,
    );
    let mut monitor = home.monitor(true);
    let polled = poll(&mut monitor, completed + Duration::minutes(5));
    assert!(!monitor.had_source_error());
    assert_eq!(polled.turns.len(), 1);
    let turn = &polled.turns[0];
    assert_eq!(
        turn.id,
        digest(&[
            "kimi-code",
            "conv-22ebc177fa959871b7c04a95",
            "0",
            "1791543242286"
        ])
    );
    assert_eq!(turn.client, KIMI_CLIENT);
    assert_eq!(turn.parser_version, KIMI_PARSER_VERSION);
    assert_eq!(turn.metric_version, KIMI_METRIC_VERSION);
    assert_eq!(turn.source_kind.as_deref(), Some("primary"));
    assert_eq!(turn.completed_at, completed);
    assert!((turn.duration_seconds - 18.044).abs() < 1e-9);
    assert_eq!(turn.output_tokens, 416);
    assert_eq!(turn.model.as_deref(), Some("k2d8-preview"));
    assert_eq!(turn.reasoning_effort.as_deref(), Some("high"));
    assert_eq!(turn.provider.as_deref(), Some("moonshot"));
    assert_eq!(turn.surface, Some(ToolSurface::Desktop));
    assert_eq!(turn.input_tokens, Some(36_590));
    assert_eq!(turn.cache_read_input_tokens, Some(30_976));
    assert_eq!(turn.cache_write_input_tokens, None);
    assert_eq!(turn.reasoning_output_tokens, None);
    assert_eq!(turn.client_version, None);
    assert_eq!(turn.codex_ttft_seconds, None);
    assert_eq!(turn.provider_region, None);
    assert_eq!(turn.response_count, Some(1));
    assert_eq!(turn.response_output_tokens, Some(285));
    // From the request (at ...050) to the step end, as the contract defines a response.
    assert!((turn.response_duration_seconds.unwrap() - 10.280).abs() < 1e-9);
    assert_eq!(turn.delegated_output_tokens, Some(0));

    assert_eq!(polled.live.len(), 1);
    let response = &polled.live[0];
    assert_eq!(response.output_tokens, 285);
    assert!((response.duration_seconds - 10.280).abs() < 1e-9);
    assert_eq!(response.completed_at, completed);
    assert_eq!(response.client, KIMI_CLIENT);
    assert_eq!(response.source_kind.as_deref(), Some("primary"));
    assert_eq!(response.metric_version, KIMI_METRIC_VERSION);
    assert_eq!(response.provider.as_deref(), Some("moonshot"));
    assert_eq!(response.model.as_deref(), Some("k2d8-preview"));
    assert_eq!(response.reasoning_effort.as_deref(), Some("high"));
}

#[test]
fn the_real_capacity_failure_has_no_turn_but_its_nine_steps_are_live_responses() {
    let home = Home::new();
    let modified = at_ms(1_791_544_000_500);
    home.write(
        "conv-capacity",
        "main",
        &fixture("desktop-k2d8-capacity-failure.jsonl"),
        modified,
    );
    let mut monitor = home.monitor(true);
    let polled = poll(&mut monitor, modified + Duration::minutes(5));
    assert!(polled.turns.is_empty());
    let outputs: Vec<i64> = polled.live.iter().map(|r| r.output_tokens).collect();
    assert_eq!(outputs, [242, 313, 207, 240, 335, 414, 359, 263, 1772]);
    assert!(polled
        .live
        .iter()
        .all(|r| r.provider.as_deref() == Some("moonshot")));
}

#[test]
fn protocol_1_3_logs_without_requests_and_cli_failed_turns_produce_nothing() {
    let home = Home::new();
    let modified = at_ms(1_791_544_000_500);
    home.write(
        "conv-old",
        "main",
        &fixture("desktop-protocol-1.3.jsonl"),
        modified,
    );
    home.write(
        "conv-failed",
        "main",
        &fixture("cli-2.1.1-failed-turns.jsonl"),
        modified,
    );
    let mut monitor = home.monitor(false);
    let polled = poll(&mut monitor, modified + Duration::minutes(5));
    assert!(polled.turns.is_empty());
    assert!(polled.live.is_empty());
    assert!(!monitor.had_source_error());
}

#[test]
fn title_sessions_are_ignored_entirely() {
    let home = Home::new();
    let modified = at_ms(1_791_544_000_500);
    home.write(
        "ctitle-abc123",
        "main",
        &fixture("desktop-ctitle.jsonl"),
        modified,
    );
    // The same turn in a normal session is measured, so the title folder is what excludes it.
    let normal = home.write(
        "conv-normal",
        "main",
        &lines(&answer(1_791_543_000_000, "0", 400, 10)),
        modified,
    );
    let mut monitor = home.monitor(true);
    let polled = poll(&mut monitor, modified + Duration::minutes(5));
    assert_eq!(polled.turns.len(), 1);
    assert_eq!(polled.live.len(), 1);
    assert!(normal.exists());
    // A subagent log of a title session is ignored too.
    home.write(
        "ctitle-abc123",
        "sub-1",
        &lines(&answer(1_791_543_000_000, "0", 400, 10)),
        modified,
    );
    let polled = poll(&mut monitor, modified + Duration::minutes(6));
    assert!(polled.turns.is_empty());
}

#[test]
fn the_command_line_home_has_the_cli_surface() {
    let home = Home::new();
    let modified = at_ms(1_791_544_000_500);
    home.write(
        "conv-cli",
        "main",
        &lines(&answer(1_791_543_000_000, "0", 400, 10)),
        modified,
    );
    let mut monitor = home.monitor(false);
    let polled = poll(&mut monitor, modified + Duration::minutes(5));
    assert_eq!(polled.turns.len(), 1);
    assert_eq!(polled.turns[0].surface, Some(ToolSurface::Cli));
    assert_eq!(monitor.root("kimi-code"), Some(&home.root()));
}

#[test]
fn a_missing_home_is_not_an_error() {
    let home = Home::new();
    let mut monitor = SourceMonitor::new(
        home.empty("codex"),
        home.empty("claude"),
        home.empty("grok"),
        home.empty("gemini"),
        home.empty("opencode"),
        home.dir.path().join("absent-cli"),
        home.dir.path().join("absent-app"),
    );
    assert!(poll(&mut monitor, Utc::now()).turns.is_empty());
    assert!(!monitor.had_source_error());
    assert_eq!(monitor.root_exists("kimi-code"), Some(false));
}

// --- file discovery ----------------------------------------------------------------------------

#[test]
fn main_and_subagent_monitors_split_the_wire_logs_by_agent_folder() {
    let home = Home::new();
    let modified = Utc::now();
    let main = lines(&answer(T0, "0", 400, 10));
    home.write("conv-a", "main", &main, modified);
    home.write("conv-a", "sub-1", &main, modified);
    home.write("conv-b", "main", &main, modified);
    // Neither depth, name nor extension of a wire log: never opened.
    let stray = home
        .root()
        .join("sessions/wd_x/conv-a/agents/main/state.json");
    fs::write(&stray, &main).unwrap();
    let deep = home
        .root()
        .join("sessions/wd_x/conv-a/agents/main/more/wire.jsonl");
    fs::create_dir_all(deep.parent().unwrap()).unwrap();
    fs::write(&deep, &main).unwrap();
    let shallow = home.root().join("sessions/wd_x/wire.jsonl");
    fs::write(&shallow, &main).unwrap();
    let elsewhere = home.root().join("logs/wd_x/conv-c/agents/main/wire.jsonl");
    fs::create_dir_all(elsewhere.parent().unwrap()).unwrap();
    fs::write(&elsewhere, &main).unwrap();

    let now = at_ms(T0) + Duration::minutes(5);
    let mut primary = Monitor::new_kimi(home.root(), ToolSurface::Cli);
    let mut found = Vec::new();
    for _ in 0..3 {
        found.extend(primary.poll(now).unwrap());
    }
    let mut ids: Vec<_> = found.iter().map(|turn| turn.id.clone()).collect();
    ids.sort();
    let mut expected = vec![
        digest(&["kimi-code", "conv-a", "0", &T0.to_string()]),
        digest(&["kimi-code", "conv-b", "0", &T0.to_string()]),
    ];
    expected.sort();
    assert_eq!(ids, expected);

    let mut subagents = Monitor::new_kimi_subagents(home.root(), ToolSurface::Cli);
    let found: Vec<_> = (0..3).flat_map(|_| subagents.poll(now).unwrap()).collect();
    assert!(found.is_empty(), "subagent logs produce no metric");
    assert_eq!(subagents.take_live_responses().len(), 0);
    let events = subagents.take_delegation_events();
    assert!(events
        .iter()
        .any(|event| matches!(event, DelegationEvent::Started { .. })));
    assert!(events.iter().any(|event| matches!(
        event,
        DelegationEvent::Finished {
            output_tokens: 400,
            ..
        }
    )));
}

#[test]
fn wire_paths_have_one_exact_layout() {
    let main = Path::new("sessions/ws/s1/agents/main/wire.jsonl");
    let sub = Path::new("sessions/ws/s1/agents/sub-1/wire.jsonl");
    assert!(is_wire_path(main, false) && !is_wire_path(main, true));
    assert!(is_wire_path(sub, true) && !is_wire_path(sub, false));
    for path in [
        "sessions/ws/s1/agents/main/other.jsonl",
        "sessions/ws/s1/agents/main/x/wire.jsonl",
        "sessions/ws/s1/main/wire.jsonl",
        "sessions/s1/agents/main/wire.jsonl",
        "logs/ws/s1/agents/main/wire.jsonl",
        "sessions/ws/ctitle-1/agents/main/wire.jsonl",
        "sessions/ws/s1/agents/main/wire.json",
    ] {
        assert!(!is_wire_path(Path::new(path), false), "{path}");
        assert!(!is_wire_path(Path::new(path), true), "{path}");
    }
    assert!(can_hold_wire(Path::new("")));
    assert!(can_hold_wire(Path::new("sessions")));
    assert!(can_hold_wire(Path::new("sessions/ws/s1/agents/main")));
    assert!(!can_hold_wire(Path::new("logs")));
    assert!(!can_hold_wire(Path::new("sessions/ws/ctitle-1")));
    assert!(!can_hold_wire(Path::new("sessions/ws/s1/other")));
    assert!(!can_hold_wire(Path::new(
        "sessions/ws/s1/agents/main/deeper"
    )));
}

// --- user prompts and turn identity ------------------------------------------------------------

fn turns_with_origin(origin: Option<Value>) -> usize {
    let mut records = vec![prompt(T0, origin)];
    records.extend(step(T0, "0", 1, "end_turn", 400, 10));
    turns_of(&records).len()
}

#[test]
fn only_user_prompts_start_measured_turns() {
    for origin in [
        None,
        Some(json!({"kind": "user"})),
        Some(json!({"kind": "skill_activation", "trigger": "user-slash"})),
        Some(json!({"kind": "plugin_command", "trigger": "user-slash"})),
    ] {
        assert_eq!(turns_with_origin(origin.clone()), 1, "{origin:?}");
    }
    for origin in [
        json!({"kind": "skill_activation"}),
        json!({"kind": "skill_activation", "trigger": "model"}),
        json!({"kind": "plugin_command", "trigger": "hook"}),
        json!({"kind": "system_trigger"}),
        json!({"kind": "injection"}),
        json!({"kind": "automation", "trigger": "user-slash"}),
        json!({}),
        json!({"trigger": "user-slash"}),
        json!("user"),
        Value::Null,
    ] {
        assert_eq!(turns_with_origin(Some(origin.clone())), 0, "{origin:?}");
    }
}

#[test]
fn a_system_triggered_turn_is_unmeasured_but_its_steps_are_still_live_responses() {
    let mut records = vec![prompt(T0, Some(json!({"kind": "system_trigger"})))];
    records.extend(step(T0, "0", 1, "end_turn", 400, 10));
    let mut parser = main_parser();
    assert!(feed(&mut parser, &records).is_empty());
    let live = parser.take_responses();
    assert_eq!(live.len(), 1);
    assert_eq!(live[0].output_tokens, 400);
}

#[test]
fn the_latest_prompt_starts_the_turn_and_a_started_turn_clears_it() {
    // Two prompts before one turn: the later one is the start.
    let mut records = vec![prompt(T0, None), prompt(T0 + 1_000, None)];
    records.extend(step(T0 + 1_000, "0", 1, "end_turn", 400, 10));
    let turn = the_turn(&records);
    assert!((turn.duration_seconds - 10.002).abs() < 1e-9);
    assert_eq!(turn.completed_at, at_ms(T0 + 1_000 + 2 + 10_000));
    // The remembered prompt is gone after a turn starts: the next turn without a prompt is
    // unmeasured.
    let mut records = answer(T0, "0", 400, 10);
    records.extend(step(T0 + 20_000, "1", 1, "end_turn", 400, 10));
    let turns = turns_of(&records);
    assert_eq!(turns.len(), 1);
    assert_eq!(
        turns[0].id,
        digest(&["kimi-code", SESSION, "0", &T0.to_string()])
    );
}

#[test]
fn a_turn_whose_first_observed_step_is_not_step_one_is_not_measured() {
    // A reader that started mid-file and missed the turn's first step.
    let mut records = vec![prompt(T0, None)];
    records.extend(step(T0, "0", 2, "end_turn", 400, 10));
    assert!(turns_of(&records).is_empty());
    // The log of a session whose beginning was not seen at all.
    let mut parser = main_parser();
    parser.begin_mid_file();
    let mut records = step(T0, "3", 4, "end_turn", 400, 10);
    records.extend(answer(T0 + 60_000, "4", 300, 10));
    let turns = feed(&mut parser, &records);
    assert_eq!(turns.len(), 1);
    assert_eq!(
        turns[0].id,
        digest(&["kimi-code", SESSION, "4", &(T0 + 60_000).to_string()])
    );
}

#[test]
fn a_tail_that_starts_inside_a_turn_measures_none_of_it_but_a_replay_measures_it() {
    let home = Home::new();
    let mut records = vec![prompt(T0, None)];
    records.extend(step(T0, "0", 1, "tool_use", 300, 10));
    records.push(begin(T0 + 20_000, "0", 2));
    records.push(request(T0 + 20_001, "0", 2, "k2d8-preview", "kimi", "high"));
    let mut bytes = lines(&records);
    // Filler pushes the end of the turn into the recent tail only.
    let filler = json!({"type": "config.update", "time": T0 + 21_000, "pad": "x".repeat(1_000)});
    for _ in 0..400 {
        bytes.extend_from_slice(filler.to_string().as_bytes());
        bytes.push(b'\n');
    }
    bytes.extend(lines(&[end(T0 + 30_000, "0", 2, "end_turn", 300)]));
    let path = home.write(SESSION, "main", &bytes, at_ms(T0 + 30_000));
    let now = at_ms(T0 + 60_000);

    let mut tail = IncrementalReader::recent_tail_kimi(path.clone(), None);
    let mut replay = IncrementalReader::beginning_kimi(path, None);
    let mut seen_by_tail = Vec::new();
    let mut seen_by_replay = Vec::new();
    for _ in 0..40 {
        seen_by_tail.extend(tail.poll(65_536, now).unwrap());
        seen_by_replay.extend(replay.poll(65_536, now).unwrap());
    }
    assert!(seen_by_tail.is_empty());
    assert_eq!(seen_by_replay.len(), 1);
    assert_eq!(seen_by_replay[0].output_tokens, 600);
    assert_eq!(seen_by_replay[0].response_count, Some(2));
    // The tail never saw the step begin, so it has no response either.
    assert!(tail.take_responses().is_empty());
    assert!(replay.take_responses().is_empty(), "replays are not live");
}

// --- steps -------------------------------------------------------------------------------------

#[test]
fn a_retried_call_uses_the_latest_request() {
    let records = vec![
        prompt(T0, None),
        begin(T0 + 1, "0", 1),
        request(T0 + 2, "0", 1, "old-model", "openai", "low"),
        request(T0 + 5_000, "0", 1, "k2d8-preview", "kimi", "high"),
        end(T0 + 15_000, "0", 1, "end_turn", 400),
    ];
    let turn = the_turn(&records);
    assert_eq!(turn.model.as_deref(), Some("k2d8-preview"));
    assert_eq!(turn.provider.as_deref(), Some("moonshot"));
    assert_eq!(turn.reasoning_effort.as_deref(), Some("high"));
    // The response is timed from the call that answered.
    assert!((turn.response_duration_seconds.unwrap() - 10.0).abs() < 1e-9);
    assert!((turn.duration_seconds - 15.0).abs() < 1e-9);
}

#[test]
fn a_request_belongs_to_the_open_step_it_names() {
    let records = vec![
        prompt(T0, None),
        // Before the step began, for another step, for another turn, malformed: all ignored.
        request(T0, "0", 1, "early", "kimi", "high"),
        begin(T0 + 1, "0", 1),
        request(T0 + 2, "0", 2, "other-step", "kimi", "high"),
        request(T0 + 3, "9", 1, "other-turn", "kimi", "high"),
        json!({"type": "llm.request", "time": T0 + 4, "model": "no-turn-step", "provider": "kimi"}),
        json!({"type": "llm.request", "time": T0 + 5, "model": "number", "turnStep": 0.1}),
        request(T0 + 6, "0", 1, "real", "kimi", "medium"),
        end(T0 + 10_006, "0", 1, "end_turn", 400),
    ];
    let turn = the_turn(&records);
    assert_eq!(turn.model.as_deref(), Some("real"));
    assert_eq!(turn.reasoning_effort.as_deref(), Some("medium"));
    // A request that came after the step ended is no request of a later step either.
    let records = vec![
        prompt(T0, None),
        begin(T0 + 1, "0", 1),
        end(T0 + 10_000, "0", 1, "end_turn", 400),
        request(T0 + 10_001, "0", 1, "late", "kimi", "high"),
    ];
    assert!(turns_of(&records).is_empty());
}

#[test]
fn every_failing_finish_reason_discards_the_turn_and_is_no_live_response() {
    for finish in [
        Some("interrupted"),
        Some("error"),
        Some("filtered"),
        Some("max_tokens"),
        Some("paused"),
        Some("other"),
        Some("something-new"),
        None,
    ] {
        let mut parser = main_parser();
        let records = vec![
            prompt(T0, None),
            begin(T0 + 1, "0", 1),
            request(T0 + 2, "0", 1, "k2d8-preview", "kimi", "high"),
            end_with(T0 + 10_000, "0", 1, finish, Some(usage(100, 400, 50))),
        ];
        assert!(feed(&mut parser, &records).is_empty(), "{finish:?}");
        assert!(parser.take_responses().is_empty(), "{finish:?}");
    }
}

#[test]
fn a_failed_step_anywhere_in_the_turn_discards_it() {
    let mut records = vec![prompt(T0, None)];
    records.extend(step(T0, "0", 1, "tool_use", 300, 10));
    records.extend(step(T0 + 11_000, "0", 2, "max_tokens", 300, 10));
    records.extend(step(T0 + 22_000, "0", 3, "end_turn", 300, 10));
    let mut parser = main_parser();
    assert!(feed(&mut parser, &records).is_empty());
    // The steps that succeeded are still responses.
    assert_eq!(parser.take_responses().len(), 2);
}

#[test]
fn missing_or_invalid_usage_fails_the_step() {
    let good = usage(100, 400, 50);
    let mut cases: Vec<Option<Value>> = vec![
        None,
        Some(Value::Null),
        Some(json!("many")),
        Some(json!({})),
        Some(json!({"inputOther": 1, "output": 400, "inputCacheRead": 1})),
        Some(json!({"inputOther": 1, "output": -1, "inputCacheRead": 1, "inputCacheCreation": 0})),
        Some(
            json!({"inputOther": 1.5, "output": 400, "inputCacheRead": 1, "inputCacheCreation": 0}),
        ),
        Some(
            json!({"inputOther": "1", "output": 400, "inputCacheRead": 1, "inputCacheCreation": 0}),
        ),
        Some(
            json!({"inputOther": 1, "output": 400, "inputCacheRead": 1, "inputCacheCreation": null}),
        ),
        Some(
            json!({"inputOther": 100_000_001, "output": 400, "inputCacheRead": 1, "inputCacheCreation": 0}),
        ),
        Some(
            json!({"inputOther": 1, "output": 100_000_001, "inputCacheRead": 1, "inputCacheCreation": 0}),
        ),
    ];
    for usage in cases.drain(..) {
        let records = vec![
            prompt(T0, None),
            begin(T0 + 1, "0", 1),
            request(T0 + 2, "0", 1, "k2d8-preview", "kimi", "high"),
            end_with(T0 + 10_000, "0", 1, Some("end_turn"), usage.clone()),
        ];
        assert!(turns_of(&records).is_empty(), "{usage:?}");
    }
    // The largest accepted counts pass.
    let edge = json!({"inputOther": 100_000_000, "output": 400, "inputCacheRead": 0, "inputCacheCreation": 0});
    let records = vec![
        prompt(T0, None),
        begin(T0 + 1, "0", 1),
        request(T0 + 2, "0", 1, "k2d8-preview", "kimi", "high"),
        end_with(T0 + 10_000, "0", 1, Some("end_turn"), Some(edge)),
    ];
    assert_eq!(the_turn(&records).input_tokens, Some(100_000_000));
    assert_eq!(good["output"], 400);
}

#[test]
fn a_step_without_a_request_cannot_be_measured() {
    let records = vec![
        prompt(T0, None),
        begin(T0 + 1, "0", 1),
        end(T0 + 10_000, "0", 1, "end_turn", 400),
    ];
    let mut parser = main_parser();
    assert!(feed(&mut parser, &records).is_empty());
    assert!(parser.take_responses().is_empty());
}

#[test]
fn a_step_that_never_ended_while_another_began_fails_the_turn() {
    let mut records = vec![prompt(T0, None), begin(T0 + 1, "0", 1)];
    records.extend(step(T0 + 100, "0", 2, "end_turn", 400, 10));
    assert!(turns_of(&records).is_empty());
}

#[test]
fn steps_sum_into_the_turn_and_only_qualifying_steps_are_responses() {
    let mut records = vec![prompt(T0, None)];
    // 100 tokens (short), 300 in 10 s, then the answer: 250 in 5 s.
    records.extend(step(T0, "0", 1, "tool_use", 100, 2));
    records.extend(step(T0 + 3_000, "0", 2, "tool_use", 300, 10));
    records.extend(step(T0 + 14_000, "0", 3, "end_turn", 250, 5));
    let turn = the_turn(&records);
    assert_eq!(turn.output_tokens, 650);
    assert_eq!(turn.response_count, Some(2));
    assert_eq!(turn.response_output_tokens, Some(550));
    assert!((turn.response_duration_seconds.unwrap() - 15.0).abs() < 1e-9);
    // Prompt cache: Σ (inputOther + read + creation) and Σ read; no write is reported.
    assert_eq!(turn.input_tokens, Some(3 * 150));
    assert_eq!(turn.cache_read_input_tokens, Some(3 * 50));
    assert_eq!(turn.cache_write_input_tokens, None);
    assert_eq!(turn.completed_at, at_ms(T0 + 14_000 + 2 + 5_000));
    assert!((turn.duration_seconds - 19.002).abs() < 1e-9);
    assert_eq!(turn.surface, Some(ToolSurface::Cli));
    assert_eq!(turn.source_kind.as_deref(), Some("primary"));
}

#[test]
fn no_qualifying_step_leaves_the_response_fields_absent() {
    let turn = the_turn(&answer(T0, "0", 150, 10));
    assert_eq!(turn.response_count, None);
    assert_eq!(turn.response_output_tokens, None);
    assert_eq!(turn.response_duration_seconds, None);
}

#[test]
fn the_cache_creation_count_is_part_of_the_input_but_no_cache_write_is_reported() {
    let records = vec![
        prompt(T0, None),
        begin(T0 + 1, "0", 1),
        request(T0 + 2, "0", 1, "k2d8-preview", "kimi", "high"),
        end_with(
            T0 + 10_000,
            "0",
            1,
            Some("end_turn"),
            Some(
                json!({"inputOther": 10, "output": 400, "inputCacheRead": 20, "inputCacheCreation": 30}),
            ),
        ),
    ];
    let turn = the_turn(&records);
    assert_eq!(turn.input_tokens, Some(60));
    assert_eq!(turn.cache_read_input_tokens, Some(20));
    assert_eq!(turn.cache_write_input_tokens, None);
}

// --- model, provider and effort ----------------------------------------------------------------

fn turn_with_requests(requests: &[(&str, &str, &str)]) -> TurnMetric {
    let mut records = vec![prompt(T0, None)];
    for (index, (model, provider, effort)) in requests.iter().enumerate() {
        let number = index as u64 + 1;
        let at = T0 + index as i64 * 20_000;
        records.push(begin(at + 1, "0", number));
        records.push(request(at + 2, "0", number, model, provider, effort));
        let finish = if number as usize == requests.len() {
            "end_turn"
        } else {
            "tool_use"
        };
        records.push(end(at + 10_000, "0", number, finish, 300));
    }
    the_turn(&records)
}

#[test]
fn kimi_provider_is_moonshot_and_any_other_is_unknown() {
    for (provider, expected) in [
        ("kimi", "moonshot"),
        ("openai", "unknown"),
        ("anthropic", "unknown"),
        ("Kimi", "unknown"),
        ("moonshot", "unknown"),
        ("", "unknown"),
    ] {
        let turn = turn_with_requests(&[("m", provider, "high")]);
        assert_eq!(turn.provider.as_deref(), Some(expected), "{provider}");
    }
    // No provider at all.
    let mut request = request(T0 + 2, "0", 1, "m", "kimi", "high");
    request.as_object_mut().unwrap().remove("provider");
    let records = vec![
        prompt(T0, None),
        begin(T0 + 1, "0", 1),
        request,
        end(T0 + 10_000, "0", 1, "end_turn", 400),
    ];
    assert_eq!(the_turn(&records).provider.as_deref(), Some("unknown"));
}

#[test]
fn steps_that_disagree_leave_model_effort_and_provider_unknown() {
    let turn = turn_with_requests(&[("a", "kimi", "high"), ("a", "kimi", "high")]);
    assert_eq!(turn.model.as_deref(), Some("a"));
    assert_eq!(turn.reasoning_effort.as_deref(), Some("high"));
    let turn = turn_with_requests(&[("a", "kimi", "high"), ("b", "kimi", "high")]);
    assert_eq!(turn.model, None);
    assert_eq!(turn.reasoning_effort.as_deref(), Some("high"));
    let turn = turn_with_requests(&[("a", "kimi", "high"), ("a", "kimi", "low")]);
    assert_eq!(turn.reasoning_effort, None);
    assert_eq!(turn.model.as_deref(), Some("a"));
    let turn = turn_with_requests(&[("a", "kimi", "high"), ("a", "openai", "high")]);
    assert_eq!(turn.provider.as_deref(), Some("unknown"));
}

#[test]
fn only_the_shared_reasoning_efforts_are_kept() {
    for effort in [
        "none", "minimal", "low", "medium", "high", "xhigh", "max", "ultra",
    ] {
        let turn = turn_with_requests(&[("m", "kimi", effort)]);
        assert_eq!(turn.reasoning_effort.as_deref(), Some(effort));
    }
    for effort in ["on", "off", "", "HIGH", "auto"] {
        let turn = turn_with_requests(&[("m", "kimi", effort)]);
        assert_eq!(turn.reasoning_effort, None, "{effort}");
    }
}

#[test]
fn a_model_must_be_a_safe_identifier() {
    let long = "m".repeat(81);
    for model in ["", "has space", "slash/model", "ünï", long.as_str()] {
        assert_eq!(
            turn_with_requests(&[(model, "kimi", "high")]).model,
            None,
            "{model}"
        );
    }
    for model in [
        "kimi-for-coding",
        "k2d8-preview",
        "a.b_c-1",
        &"m".repeat(80),
    ] {
        assert_eq!(
            turn_with_requests(&[(model, "kimi", "high")])
                .model
                .as_deref(),
            Some(model)
        );
    }
    // One unsafe model among the steps leaves the turn without a common model.
    assert_eq!(
        turn_with_requests(&[("ok", "kimi", "high"), ("bad model", "kimi", "high")]).model,
        None
    );
}

// --- completion --------------------------------------------------------------------------------

#[test]
fn a_turn_completes_and_is_emitted_at_its_first_end_turn() {
    let mut parser = main_parser();
    let records = answer(T0, "0", 400, 10);
    let (last, before) = records.split_last().unwrap();
    assert!(feed(&mut parser, before).is_empty());
    let turn = parser.consume(last.to_string().as_bytes()).unwrap();
    assert_eq!(turn.output_tokens, 400);
    assert_eq!(turn.completed_at, at_ms(T0 + 2 + 10_000));
    // Nothing is held back for a flush at the end of the file, and nothing is reported twice.
    assert!(parser.flush_pending(Utc::now(), true).is_none());
    assert!(parser.flush_pending(Utc::now(), false).is_none());
}

#[test]
fn a_step_of_another_turn_does_not_delay_or_repeat_a_completed_turn() {
    let mut parser = main_parser();
    let mut records = answer(T0, "0", 400, 10);
    records.extend(answer(T0 + 30_000, "1", 300, 10));
    let turns = feed(&mut parser, &records);
    let outputs: Vec<i64> = turns.iter().map(|turn| turn.output_tokens).collect();
    assert_eq!(outputs, [400, 300]);
}

#[test]
fn a_turn_that_is_still_running_is_not_emitted() {
    let mut parser = main_parser();
    let mut records = vec![prompt(T0, None)];
    records.extend(step(T0, "0", 1, "tool_use", 400, 10));
    assert!(feed(&mut parser, &records).is_empty());
    assert!(parser.flush_pending(Utc::now(), true).is_none());
}

#[test]
fn steps_after_the_first_end_turn_belong_to_no_measured_turn() {
    // Queued input or a hook continues the turn after `end_turn`: the turn is what it was at the
    // first answer, however the file is read; the later qualifying steps are live responses only.
    let mut parser = main_parser();
    let mut records = answer(T0, "0", 400, 10);
    records.extend(step(T0 + 12_000, "0", 2, "tool_use", 300, 5));
    records.extend(step(T0 + 20_000, "0", 3, "end_turn", 250, 5));
    records.extend(step(T0 + 30_000, "0", 4, "end_turn", 260, 5));
    let turns = feed(&mut parser, &records);
    assert_eq!(turns.len(), 1);
    assert_eq!(turns[0].output_tokens, 400);
    assert_eq!(turns[0].response_count, Some(1));
    assert_eq!(turns[0].completed_at, at_ms(T0 + 2 + 10_000));
    let live: Vec<i64> = parser
        .take_responses()
        .iter()
        .map(|r| r.output_tokens)
        .collect();
    assert_eq!(live, [400, 300, 250, 260]);
}

#[test]
fn a_failure_after_the_first_end_turn_does_not_affect_the_emitted_turn() {
    let mut parser = main_parser();
    let mut records = answer(T0, "0", 400, 10);
    let completed = feed(&mut parser, &records);
    assert_eq!(completed.len(), 1);
    records.clear();
    // A step that fails, a step left open, an interruption, an abort and a failed end record.
    records.extend(step(T0 + 12_000, "0", 2, "error", 300, 5));
    records.push(begin(T0 + 20_000, "0", 3));
    records.push(begin(T0 + 21_000, "0", 4));
    records.push(
        json!({"type": "turn.step.interrupted", "time": T0 + 22_000, "turnId": 0, "step": 4}),
    );
    records.push(json!({"type": "prompt.aborted", "time": T0 + 23_000}));
    records
        .push(json!({"type": "turn.ended", "time": T0 + 24_000, "turnId": 0, "reason": "failed"}));
    assert!(feed(&mut parser, &records).is_empty());

    // The same holds for a subagent's finished work item.
    let mut parser = subagent_parser();
    let mut all = answer(T0, "0", 400, 10);
    all.extend(records);
    feed(&mut parser, &all);
    let events = events_of(&mut parser);
    assert_eq!(events.len(), 2, "{events:?}");
    assert!(matches!(
        events[1],
        DelegationEvent::Finished {
            output_tokens: 400,
            ..
        }
    ));
}

#[test]
fn a_turn_that_never_ended_a_step_is_discarded_when_another_turn_begins() {
    // The desktop app writes nothing for a call that failed (over capacity).
    let mut parser = main_parser();
    let mut records = vec![prompt(T0, None)];
    records.extend(step(T0, "0", 1, "tool_use", 400, 10));
    records.push(begin(T0 + 12_000, "0", 2));
    records.push(request(T0 + 12_001, "0", 2, "k2d8-preview", "kimi", "high"));
    records.extend(answer(T0 + 600_000, "1", 300, 10));
    let turns = feed(&mut parser, &records);
    assert_eq!(turns.len(), 1);
    assert_eq!(turns[0].output_tokens, 300);
}

#[test]
fn a_turn_between_steps_is_discarded_when_another_turn_begins() {
    let mut records = vec![prompt(T0, None)];
    records.extend(step(T0, "0", 1, "tool_use", 400, 10));
    records.extend(answer(T0 + 600_000, "1", 300, 10));
    let turns = turns_of(&records);
    assert_eq!(turns.len(), 1);
    assert_eq!(turns[0].output_tokens, 300);
}

#[test]
fn turn_end_records_discard_the_turn() {
    let ended = |kind: &str, turn: Value, field: &str, value: &str| json!({"type": kind, "time": T0 + 20_000, field: value, "turnId": turn});
    let discarding = [
        ended("turn.ended", json!(0), "reason", "failed"),
        ended("turn.ended", json!("0"), "reason", "aborted"),
        ended("turn.ended", json!(0), "reason", "cancelled"),
        ended("turn.ended", json!(0), "reason", "interrupted"),
        ended("turn.ended", json!(0), "reason", "error"),
        ended("agent.turn.ended", json!(0), "outcome", "failed"),
        ended("agent.turn.ended", json!(0), "outcome", "aborted"),
        json!({"type": "turn.step.interrupted", "time": T0 + 20_000, "turnId": 0, "step": 1}),
    ];
    for record in discarding {
        // After the answer the turn is complete and stays emitted.
        let mut records = answer(T0, "0", 400, 10);
        records.push(record.clone());
        assert_eq!(turns_of(&records).len(), 1, "{record}");
        // Before it, while the turn runs.
        let mut records = vec![prompt(T0, None)];
        records.push(begin(T0 + 1, "0", 1));
        records.push(request(T0 + 2, "0", 1, "k2d8-preview", "kimi", "high"));
        records.push(record.clone());
        records.push(end(T0 + 10_000, "0", 1, "end_turn", 400));
        assert!(turns_of(&records).is_empty(), "{record}");
    }
}

#[test]
fn other_end_values_and_other_turns_are_ignored() {
    let ignored = [
        json!({"type": "turn.ended", "time": T0 + 20_000, "turnId": 0, "reason": "completed"}),
        json!({"type": "turn.ended", "time": T0 + 20_000, "turnId": 0}),
        json!({"type": "agent.turn.ended", "time": T0 + 20_000, "turnId": 0, "outcome": "completed"}),
        json!({"type": "agent.turn.ended", "time": T0 + 20_000, "turnId": 0, "outcome": "error"}),
        json!({"type": "turn.ended", "time": T0 + 20_000, "turnId": 7, "reason": "failed"}),
        json!({"type": "turn.ended", "time": T0 + 20_000, "reason": "failed"}),
        json!({"type": "turn.step.interrupted", "time": T0 + 20_000, "turnId": 7, "step": 1}),
        json!({"type": "turn.ended", "turnId": 0, "reason": "failed"}),
    ];
    for record in ignored {
        let mut records = answer(T0, "0", 400, 10);
        records.push(record.clone());
        assert_eq!(turns_of(&records).len(), 1, "{record}");
    }
}

#[test]
fn an_aborted_prompt_discards_only_a_turn_that_is_still_open() {
    let aborted = json!({"type": "prompt.aborted", "time": T0 + 20_000});
    let mut records = vec![prompt(T0, None)];
    records.extend(step(T0, "0", 1, "tool_use", 400, 10));
    records.push(aborted.clone());
    records.extend(step(T0 + 21_000, "0", 2, "end_turn", 400, 10));
    assert!(turns_of(&records).is_empty());
    // A turn that already answered is complete.
    let mut records = answer(T0, "0", 400, 10);
    records.push(aborted);
    assert_eq!(turns_of(&records).len(), 1);
}

#[test]
fn records_without_a_finite_integer_time_are_ignored() {
    let mut records = answer(T0, "0", 400, 10);
    for record in &mut records {
        record.as_object_mut().unwrap().remove("time");
    }
    assert!(turns_of(&records).is_empty());
    let mut records = answer(T0, "0", 400, 10);
    records[0]["time"] = json!(T0 as f64 + 0.5);
    assert!(
        turns_of(&records).is_empty(),
        "the prompt has no usable time"
    );
    let mut records = answer(T0, "0", 400, 10);
    records[0]["time"] = json!("1790000000000");
    assert!(turns_of(&records).is_empty());
}

#[test]
fn malformed_lines_and_unknown_records_are_skipped() {
    let mut parser = main_parser();
    for line in [
        &b""[..],
        b"not json",
        b"[]",
        b"{\"type\": 3, \"time\": 1}",
        b"{\"type\": \"context.append_loop_event\", \"time\": 1}",
        b"{\"type\": \"context.append_loop_event\", \"time\": 1, \"event\": {\"type\": \"step.begin\"}}",
        b"{\"type\": \"context.append_loop_event\", \"time\": 1, \"event\": {\"type\": \"step.begin\", \"turnId\": \"0\", \"step\": 0}}",
        b"{\"type\": \"context.append_loop_event\", \"time\": 1, \"event\": {\"type\": \"step.begin\", \"turnId\": \"0\", \"step\": 1.5}}",
        b"{\"type\": \"context.append_loop_event\", \"time\": 1, \"event\": {\"type\": \"step.begin\", \"turnId\": true, \"step\": 1}}",
    ] {
        assert!(parser.consume(line).is_none());
    }
    assert_eq!(feed(&mut parser, &answer(T0, "0", 400, 10)).len(), 1);
}

#[test]
fn a_turn_must_last_and_stay_below_two_thousand_tokens_per_second() {
    // 30,000 tokens in 10 s is 3,000 tok/s: a measurement error.
    assert!(turns_of(&answer(T0, "0", 30_000, 10)).is_empty());
    // 20,000 in exactly 10.002 s is below the bound.
    assert_eq!(turns_of(&answer(T0, "0", 20_000, 10)).len(), 1);
    // An end before the start is no duration.
    let records = vec![
        prompt(T0, None),
        begin(T0 + 1, "0", 1),
        request(T0 + 2, "0", 1, "k2d8-preview", "kimi", "high"),
        end(T0 - 5_000, "0", 1, "end_turn", 400),
    ];
    assert!(turns_of(&records).is_empty());
}

#[test]
fn live_responses_follow_the_response_rules() {
    let mut parser = main_parser();
    let mut records = vec![prompt(T0, None)];
    // Too short, too fast (4,000 tok/s), too slow (over 600 s), then fine.
    records.extend(step(T0, "0", 1, "tool_use", 199, 10));
    records.extend(step(T0 + 11_000, "0", 2, "tool_use", 40_000, 10));
    records.extend(step(T0 + 22_000, "0", 3, "tool_use", 400, 601));
    records.extend(step(T0 + 700_000, "0", 4, "end_turn", 200, 10));
    feed(&mut parser, &records);
    let live = parser.take_responses();
    assert_eq!(live.len(), 1);
    assert_eq!(live[0].output_tokens, 200);
    assert_eq!(live[0].completed_at, at_ms(T0 + 700_000 + 2 + 10_000));
    assert!(parser.take_responses().is_empty(), "drained");
}

#[test]
fn live_responses_come_from_unmeasured_and_discarded_turns_too() {
    let mut parser = main_parser();
    let mut records = vec![prompt(T0, Some(json!({"kind": "injection"})))];
    records.extend(step(T0, "0", 1, "tool_use", 300, 10));
    records.extend(step(T0 + 11_000, "0", 2, "error", 300, 10));
    records.extend(step(T0 + 22_000, "0", 3, "tool_use", 300, 10));
    feed(&mut parser, &records);
    assert_eq!(parser.take_responses().len(), 2);
}

#[test]
fn the_turn_id_may_be_a_number_in_end_records_and_a_string_in_steps() {
    // The integer id of an end record meets the string id of the running turn's steps.
    let mut records = vec![prompt(T0, None), begin(T0 + 1, "12", 1)];
    records.push(request(T0 + 2, "12", 1, "k2d8-preview", "kimi", "high"));
    records
        .push(json!({"type": "turn.ended", "time": T0 + 5_000, "turnId": 12, "reason": "failed"}));
    records.push(end(T0 + 10_000, "12", 1, "end_turn", 400));
    assert!(turns_of(&records).is_empty());
    let turn = the_turn(&answer(T0, "12", 400, 10));
    assert_eq!(
        turn.id,
        digest(&["kimi-code", SESSION, "12", &T0.to_string()])
    );
}

// --- subagents ---------------------------------------------------------------------------------

fn events_of(parser: &mut KimiWireParser) -> Vec<DelegationEvent> {
    parser.take_delegation_events()
}

#[test]
fn a_subagent_log_reports_delegated_work_and_no_metric_or_live_response() {
    let mut parser = subagent_parser();
    let mut records = vec![prompt(T0, Some(json!({"kind": "system_trigger"})))];
    records.extend(step(T0, "0", 1, "tool_use", 300, 10));
    records.extend(step(T0 + 11_000, "0", 2, "end_turn", 250, 5));
    assert!(feed(&mut parser, &records).is_empty());
    assert!(parser.take_responses().is_empty());
    let events = events_of(&mut parser);
    let root = root_session_key(KIMI_CLIENT, SESSION);
    let work_id = digest(&[
        "subagent",
        "kimi-code",
        SESSION,
        "sub-1",
        "0",
        &T0.to_string(),
    ]);
    assert_eq!(
        events,
        [
            DelegationEvent::Started {
                work_id: work_id.clone(),
                root_session: root,
                started_at: at_ms(T0),
            },
            DelegationEvent::Finished {
                work_id,
                output_tokens: 550,
                finished_at: at_ms(T0 + 11_000 + 2 + 5_000),
            },
        ]
    );
}

#[test]
fn every_prompt_kind_counts_in_a_subagent_log_but_the_step_must_still_be_the_first() {
    for origin in [
        None,
        Some(json!({"kind": "user"})),
        Some(json!({"kind": "injection"})),
        Some(json!({})),
    ] {
        let mut parser = subagent_parser();
        let mut records = vec![prompt(T0, origin)];
        records.extend(step(T0, "0", 1, "end_turn", 300, 10));
        feed(&mut parser, &records);
        assert_eq!(events_of(&mut parser).len(), 2);
    }
    let mut parser = subagent_parser();
    let mut records = vec![prompt(T0, None)];
    records.extend(step(T0, "0", 2, "end_turn", 300, 10));
    feed(&mut parser, &records);
    assert!(
        events_of(&mut parser).is_empty(),
        "started mid-turn: not a work item"
    );
}

#[test]
fn a_failed_or_unfinished_subagent_turn_is_discarded_work() {
    let discarded = |parser: &mut KimiWireParser| {
        let events = events_of(parser);
        assert!(matches!(events[0], DelegationEvent::Started { .. }));
        assert_eq!(events.len(), 2, "{events:?}");
        assert!(matches!(events[1], DelegationEvent::Discarded { .. }));
    };
    // A failed step.
    let mut parser = subagent_parser();
    let mut records = vec![prompt(T0, None)];
    records.extend(step(T0, "0", 1, "error", 300, 10));
    feed(&mut parser, &records);
    discarded(&mut parser);
    // A turn left open when another begins.
    let mut parser = subagent_parser();
    let mut records = vec![prompt(T0, None), begin(T0 + 1, "0", 1)];
    records.extend(answer(T0 + 60_000, "1", 300, 10));
    feed(&mut parser, &records);
    let events = events_of(&mut parser);
    assert!(matches!(events[1], DelegationEvent::Discarded { .. }));
    assert!(matches!(events[3], DelegationEvent::Finished { .. }));
    // A turn.ended failure while the turn runs, once.
    let mut parser = subagent_parser();
    let mut records = vec![prompt(T0, None)];
    records.extend(step(T0, "0", 1, "tool_use", 300, 10));
    records
        .push(json!({"type": "turn.ended", "time": T0 + 20_000, "turnId": 0, "reason": "failed"}));
    records.push(
        json!({"type": "turn.step.interrupted", "time": T0 + 20_000, "turnId": 0, "step": 1}),
    );
    feed(&mut parser, &records);
    discarded(&mut parser);
    // A reader that is reset settles the open work as discarded.
    let mut parser = subagent_parser();
    feed(&mut parser, &[prompt(T0, None), begin(T0 + 1, "0", 1)]);
    parser.reset(String::new());
    let events = events_of(&mut parser);
    assert!(matches!(events[1], DelegationEvent::Discarded { .. }));
}

#[test]
fn a_main_turn_reports_itself_for_attribution_with_the_session_as_root() {
    let mut parser = main_parser();
    let turn = feed(&mut parser, &answer(T0, "0", 400, 10)).remove(0);
    assert_eq!(
        events_of(&mut parser),
        [DelegationEvent::Turn {
            turn_id: turn.id,
            root_session: root_session_key(KIMI_CLIENT, SESSION),
            started_at: at_ms(T0),
        }]
    );
}

#[test]
fn the_session_and_agent_come_from_the_log_path() {
    let path = Path::new("/home/u/.kimi-code/sessions/wd_x/conv-1/agents/main/wire.jsonl");
    let mut parser = KimiWireParser::for_path(path, Some(ToolSurface::Desktop));
    let turn = feed(&mut parser, &answer(T0, "0", 400, 10)).remove(0);
    assert_eq!(
        turn.id,
        digest(&["kimi-code", "conv-1", "0", &T0.to_string()])
    );
    assert_eq!(turn.surface, Some(ToolSurface::Desktop));
    let path = Path::new("/home/u/.kimi-code/sessions/wd_x/conv-1/agents/sub-9/wire.jsonl");
    let mut parser = KimiWireParser::for_path(path, None);
    assert!(feed(&mut parser, &answer(T0, "0", 400, 10)).is_empty());
    assert_eq!(events_of(&mut parser).len(), 2);
}

#[test]
fn subagent_output_is_attributed_to_the_main_turn_that_started_it() {
    let home = Home::new();
    // The main turn runs 60 s; the subagent starts inside it and answers with 700 tokens.
    let mut main = vec![prompt(T0, None)];
    main.extend(step(T0, "0", 1, "tool_use", 300, 10));
    main.extend(step(T0 + 60_000, "0", 2, "end_turn", 300, 10));
    let mut sub = vec![prompt(T0 + 15_000, Some(json!({"kind": "system_trigger"})))];
    sub.extend(step(T0 + 15_000, "0", 1, "end_turn", 700, 20));
    let modified = at_ms(T0 + 80_000);
    home.write(SESSION, "main", &lines(&main), modified);
    home.write(SESSION, "sub-1", &lines(&sub), modified);
    // Another session's subagent is not this turn's work.
    home.write("conv-other", "sub-1", &lines(&sub), modified);
    let mut monitor = home.monitor(false);
    let polled = poll(&mut monitor, modified + Duration::minutes(5));
    assert_eq!(polled.turns.len(), 1);
    assert_eq!(polled.turns[0].output_tokens, 600);
    assert_eq!(polled.turns[0].delegated_output_tokens, Some(700));
    assert_eq!(
        polled.live.len(),
        2,
        "the subagent's steps are no live responses"
    );
}

// --- launch checkpoints ------------------------------------------------------------------------

#[test]
fn a_file_read_to_its_end_is_checkpointed_and_not_read_again() {
    let home = Home::new();
    let modified = at_ms(T0 + 20_000);
    let path = home.write(SESSION, "main", &lines(&answer(T0, "0", 400, 10)), modified);
    let now = modified + Duration::hours(1);
    let mut first = home.monitor(false);
    assert_eq!(poll(&mut first, now).turns.len(), 1);
    let checkpoints = first.checkpoints(&SourceCheckpoints::default());
    assert_eq!(checkpoints.kimi_primary.len(), 1);
    assert_eq!(checkpoints.kimi_subagents.len(), 0);
    // The checkpoints travel through the history file's JSON.
    let checkpoints: SourceCheckpoints =
        serde_json::from_value(serde_json::to_value(&checkpoints).unwrap()).unwrap();

    let mut second = home.monitor(false);
    second.set_checkpoints(checkpoints.clone());
    let polled = poll(&mut second, now);
    assert!(polled.turns.is_empty(), "the unchanged file is skipped");
    assert_eq!(
        second.checkpoints(&SourceCheckpoints::default()),
        checkpoints
    );

    // A later turn is read from the live tail once the watcher reports the change.
    let mut grown = lines(&answer(T0, "0", 400, 10));
    grown.extend(lines(&answer(T0 + 60_000, "1", 300, 10)));
    fs::write(&path, grown).unwrap();
    set_modified(&path, now);
    assert!(second.note_changes(&SourceChange {
        paths: [path].into_iter().collect(),
        must_rescan: false,
    }));
    let polled = poll(&mut second, now + Duration::minutes(1));
    assert_eq!(polled.turns.len(), 1);
    assert_eq!(polled.turns[0].output_tokens, 300);
}

// --- sharing and presentation ------------------------------------------------------------------

fn kimi_metric(provider: Option<&str>, write: Option<i64>) -> TurnMetric {
    let mut metric = TurnMetric::new_observed(
        "local-kimi".into(),
        at_ms(T0),
        Some("k2d8-preview".into()),
        416,
        18.0,
        None,
        None,
        Some("primary".into()),
        provider.map(str::to_owned),
        Some("high".into()),
        KIMI_CLIENT,
        KIMI_PARSER_VERSION,
        KIMI_METRIC_VERSION,
    );
    metric.delegated_output_tokens = Some(0);
    metric.surface = Some(ToolSurface::Desktop);
    metric.set_prompt_cache(Some(1_000), Some(800), write);
    metric
}

#[test]
fn a_kimi_sample_is_shared_only_for_moonshot_or_unknown_without_a_cache_write() {
    let shared = |metric: &TurnMetric| SharedSample::from_metric(metric, Uuid::new_v4());
    for (provider, expected) in [
        (Some("moonshot"), "moonshot"),
        (Some("unknown"), "unknown"),
        (None, "unknown"),
    ] {
        let sample = shared(&kimi_metric(provider, None)).unwrap();
        assert_eq!(sample.provider, expected);
        assert_eq!(sample.client, "kimi-code");
        assert_eq!(sample.parser_version, "kimi-wire-v1");
        assert_eq!(sample.metric_version, "kimi-observed-turn-v1");
        assert_eq!(sample.app_version, "0.1.22");
        assert_eq!(sample.model, "k2d8-preview");
        assert_eq!(sample.input_tokens, Some(1_000));
        assert_eq!(sample.cache_read_input_tokens, Some(800));
        assert_eq!(sample.cache_write_input_tokens, None);
    }
    for provider in [
        "openai",
        "anthropic",
        "google",
        "xai",
        "amazon-bedrock",
        "kimi",
        "my-gateway",
    ] {
        assert!(
            shared(&kimi_metric(Some(provider), None)).is_none(),
            "{provider}"
        );
    }
    assert!(shared(&kimi_metric(Some("moonshot"), Some(0))).is_none());
    assert!(shared(&kimi_metric(Some("moonshot"), Some(5))).is_none());
    // The tuple must be exactly Kimi Code's.
    let mut other_parser = kimi_metric(Some("moonshot"), None);
    other_parser.parser_version = "kimi-wire-v0".into();
    assert!(shared(&other_parser).is_none());
    // Moonshot is attributed to no other tool.
    let mut codex = kimi_metric(Some("moonshot"), None);
    codex.client = "codex".into();
    codex.parser_version = crate::CODEX_PARSER_VERSION.into();
    codex.metric_version = crate::CODEX_METRIC_VERSION.into();
    assert_eq!(shared(&codex).unwrap().provider, "unknown");
}

#[test]
fn the_moonshot_badge_follows_the_provider_or_the_model_family() {
    for (model, provider) in [
        (None, Some("moonshot")),
        (Some("anything"), Some("moonshot")),
        (Some("k2d8-preview"), None),
        (Some("K2d8-preview"), Some("unknown")),
        (Some("kimi-for-coding"), None),
        (Some("kimi-k2"), Some("unknown")),
        (Some("k2"), None),
    ] {
        assert_eq!(
            ProviderBadge::of(model, provider),
            ProviderBadge::Moonshot,
            "{model:?}"
        );
    }
    for model in ["kilo-x", "k", "kimi", "kx", "my-kimi-model", "omega"] {
        assert_eq!(
            ProviderBadge::of(Some(model), None),
            ProviderBadge::Unknown,
            "{model}"
        );
    }
    // Explicit evidence of another provider wins over the model family.
    assert_eq!(
        ProviderBadge::of(Some("kimi-k2"), Some("openai")),
        ProviderBadge::OpenAi
    );
    assert_eq!(ProviderBadge::Moonshot.letter(), Some('M'));
    assert_eq!(ProviderBadge::Moonshot.label(), "Moonshot AI");
    assert_eq!(
        serde_json::to_value(ProviderBadge::Moonshot).unwrap(),
        json!("moonshot")
    );
}

#[test]
fn the_kimi_code_tool_can_be_selected() {
    assert!(crate::SelectionMode::parse("auto:kimi-code").is_some());
}

// --- request outcomes (contract "Request outcomes (0.1.22)") -------------------------------------

/// The records of a failed turn as Kimi Code writes them: the failed step, the interruption, the
/// turn's error and the two summaries that describe the same failure again.
fn failed_turn(at: i64, turn: &str, provider: &str, code: &str, status: Option<i64>) -> Vec<Value> {
    let details = status.map_or(
        json!({"requestId": null}),
        |status| json!({"statusCode": status, "requestId": null}),
    );
    vec![
        prompt(at, None),
        begin(at + 1, turn, 1),
        request(at + 2, turn, 1, "kimi-for-coding", provider, "high"),
        end_with(at + 1_000, turn, 1, Some("error"), None),
        json!({"type": "turn.step.interrupted", "time": at + 1_001, "turnId": turn, "step": 1,
            "reason": "error", "message": "SECRET [provider] text"}),
        json!({"type": "turn.ended", "time": at + 1_002, "turnId": turn, "reason": "failed",
            "durationMs": 1_000, "error": {"code": code, "name": "APIStatusError",
            "message": "SECRET error text", "details": details, "retryable": false}}),
        json!({"type": "agent.turn.ended", "time": at + 1_003, "turnId": turn,
            "outcome": "failed", "errorMessage": "SECRET error text"}),
        json!({"type": "prompt.completed", "time": at + 1_004, "reason": "failed"}),
    ]
}

fn outcomes_of(parser: &mut KimiWireParser, records: &[Value]) -> Vec<crate::RequestOutcome> {
    feed(parser, records);
    parser.take_outcomes()
}

#[test]
fn kimi_failures_are_the_turn_errors_of_the_providers_side_counted_once() {
    use crate::RequestOutcomeKind::{Overloaded, ServerError};
    let failure = |code: &str, status: Option<i64>| {
        outcomes_of(
            &mut main_parser(),
            &failed_turn(T0, "0", "kimi", code, status),
        )
    };
    let overloaded = failure("provider.overloaded", Some(529));
    // Four records describe the failed turn; it is one request.
    assert_eq!(overloaded.len(), 1);
    assert_eq!(overloaded[0].kind, Overloaded);
    assert_eq!(overloaded[0].model, "kimi-for-coding");
    assert_eq!(overloaded[0].provider, "moonshot");
    assert_eq!(overloaded[0].client, KIMI_CLIENT);
    assert_eq!(overloaded[0].parser_version, KIMI_PARSER_VERSION);
    assert_eq!(overloaded[0].occurred_at, at_ms(T0 + 1_002));
    assert!(!format!("{overloaded:?}").contains("SECRET"));
    let server = failure("provider.api_error", Some(502));
    assert_eq!(server.len(), 1);
    assert_eq!(server[0].kind, ServerError);
    assert_eq!(
        failure("provider.api_error", Some(500))[0].kind,
        ServerError
    );
    // Read again, it has the same key; another turn's failure has another.
    assert_eq!(
        failure("provider.api_error", Some(502))[0].dedupe_key,
        server[0].dedupe_key
    );
    let other = outcomes_of(
        &mut main_parser(),
        &failed_turn(T0 + 60_000, "1", "kimi", "provider.api_error", Some(502)),
    );
    assert_ne!(other[0].dedupe_key, server[0].dedupe_key);
    // The user's side, ambiguous or not a failure of the request.
    for (code, status) in [
        ("provider.rate_limit", Some(429)),
        ("provider.connection_error", None),
        ("provider.auth_error", Some(403)),
        ("provider.api_error", Some(400)),
        ("provider.api_error", Some(404)),
        ("provider.api_error", Some(429)),
        ("provider.api_error", None),
        ("provider.filtered", None),
        ("context.overflow", None),
        ("internal", None),
        ("auth.login_required", None),
    ] {
        assert!(failure(code, status).is_empty(), "{code} {status:?}");
    }
}

#[test]
fn a_kimi_failure_needs_the_request_of_its_own_step_on_moonshot() {
    // A third-party provider type, and a turn that failed before any request.
    assert!(outcomes_of(
        &mut main_parser(),
        &failed_turn(T0, "0", "openai", "provider.overloaded", Some(529))
    )
    .is_empty());
    let mut no_request = failed_turn(T0, "0", "kimi", "provider.overloaded", Some(529));
    no_request.remove(2);
    assert!(outcomes_of(&mut main_parser(), &no_request).is_empty());
    // A second step that fails before its request is not attributed to the first step's.
    let mut parser = main_parser();
    let mut records = answer(T0, "0", 50, 2);
    records[2] = begin(T0 + 3_000, "0", 2);
    records.truncate(3);
    records.push(
        json!({"type": "turn.ended", "time": T0 + 4_000, "turnId": "0",
        "reason": "failed", "error": {"code": "provider.overloaded",
        "details": {"statusCode": 529}}}),
    );
    let outcomes = outcomes_of(&mut parser, &records);
    assert!(outcomes.is_empty());
    // A log read from the middle has no turn to attribute it to.
    let mut mid_file = main_parser();
    mid_file.begin_mid_file();
    let tail = &failed_turn(T0, "0", "kimi", "provider.overloaded", Some(529))[5..];
    assert!(outcomes_of(&mut mid_file, tail).is_empty());
}

#[test]
fn kimi_successful_steps_count_before_the_response_filter_and_retries_not_at_all() {
    use crate::RequestOutcomeKind::Succeeded;
    // A short tool-call step and a final answer, in the main log and in a subagent's.
    let mut records = vec![prompt(T0, None)];
    records.extend(step(T0, "0", 1, "tool_use", 5, 1));
    records.extend(step(T0 + 10_000, "0", 2, "end_turn", 300, 5));
    // A retry before a step that then succeeds is only the success.
    records.push(begin(T0 + 20_000, "0", 3));
    records.push(
        json!({"type": "turn.step.retrying", "time": T0 + 20_001, "turnId": "0",
        "step": 3, "failedAttempt": 1, "nextAttempt": 2, "maxAttempts": 3, "delayMs": 500,
        "errorName": "APIProviderOverloadedError", "errorMessage": "SECRET", "statusCode": 529}),
    );
    records.push(request(T0 + 20_500, "0", 3, "k2d8-preview", "kimi", "high"));
    records.push(end(T0 + 22_000, "0", 3, "end_turn", 40));
    let outcomes = outcomes_of(&mut main_parser(), &records);
    assert_eq!(outcomes.len(), 3);
    assert!(outcomes.iter().all(|outcome| outcome.kind == Succeeded
        && outcome.model == "k2d8-preview"
        && outcome.provider == "moonshot"));
    assert_eq!(outcomes[0].occurred_at, at_ms(T0 + 1_002));
    let keys: std::collections::HashSet<_> = outcomes
        .iter()
        .map(|outcome| outcome.dedupe_key.clone())
        .collect();
    assert_eq!(keys.len(), 3);
    // The same log read again by another parser names the same requests.
    let again = outcomes_of(&mut main_parser(), &records);
    assert_eq!(again[0].dedupe_key, outcomes[0].dedupe_key);
    // Subagent logs are requests too.
    assert_eq!(
        outcomes_of(&mut subagent_parser(), &answer(T0, "0", 50, 2)).len(),
        1
    );
    // A step without usage, a failed finish or a third-party provider is no success.
    let mut failed = vec![prompt(T0, None), begin(T0 + 1, "0", 1)];
    failed.push(request(T0 + 2, "0", 1, "k2d8-preview", "kimi", "high"));
    failed.push(end_with(T0 + 3_000, "0", 1, Some("end_turn"), None));
    assert!(outcomes_of(&mut main_parser(), &failed).is_empty());
    let mut third_party = vec![prompt(T0, None), begin(T0 + 1, "0", 1)];
    third_party.push(request(T0 + 2, "0", 1, "gpt-5", "openai", "high"));
    third_party.push(end(T0 + 3_000, "0", 1, "end_turn", 50));
    assert!(outcomes_of(&mut main_parser(), &third_party).is_empty());
}
