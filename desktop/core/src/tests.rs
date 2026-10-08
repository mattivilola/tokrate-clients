use crate::parser::JsonlEventParser;
use crate::{
    signed_request, GrokMonitor, History, Monitor, ReportedReasoningEffort, SharingQueue,
    SourceChange, SourceMonitor, TurnMetric, CLAUDE_CLIENT, CLAUDE_METRIC_VERSION,
    CLAUDE_PARSER_VERSION, CLAUDE_SUBAGENT_METRIC_VERSION, GROK_CLIENT, GROK_METRIC_VERSION,
    GROK_PARSER_VERSION, MAX_PENDING_SAMPLES,
};
use chrono::{DateTime, Duration, Utc};
use ed25519_dalek::{Signature, Verifier, VerifyingKey};
use serde_json::{json, Value};
use std::collections::HashSet;
use std::fs;
use std::fs::FileTimes;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::time::{Duration as StdDuration, SystemTime};
use uuid::Uuid;

struct TestDir(PathBuf);

impl TestDir {
    fn new() -> Self {
        let path = std::env::temp_dir().join(format!("tokrate-core-test-{}", Uuid::new_v4()));
        fs::create_dir_all(&path).unwrap();
        Self(path)
    }

    fn path(&self) -> &Path {
        &self.0
    }
}

impl Drop for TestDir {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}

/// What a folder watcher reports for writes to `paths`.
fn changed(paths: &[&Path]) -> SourceChange {
    SourceChange {
        paths: paths.iter().map(|path| path.to_path_buf()).collect(),
        must_rescan: false,
    }
}

fn time(value: &str) -> DateTime<Utc> {
    DateTime::parse_from_rfc3339(value)
        .unwrap()
        .with_timezone(&Utc)
}

fn metric(id: impl Into<String>, completed_at: DateTime<Utc>) -> TurnMetric {
    // A primary turn whose delegated output is final (it delegated nothing).
    let mut turn = TurnMetric::new(
        id.into(),
        completed_at,
        Some("gpt-test".into()),
        200,
        10.0,
        Some(1.0),
        20.0,
        None,
        Some("0.159.2".into()),
        Some(50),
        Some("primary".into()),
        Some("openai".into()),
        Some("high".into()),
    );
    turn.delegated_output_tokens = Some(0);
    turn
}

fn event(event_type: &str, payload: Value, timestamp: &str) -> Vec<u8> {
    serde_json::to_vec(&json!({ "timestamp": timestamp, "type": event_type, "payload": payload }))
        .unwrap()
}

fn jsonl(lines: &[Vec<u8>]) -> Vec<u8> {
    let mut output = Vec::new();
    for line in lines {
        output.extend_from_slice(line);
        output.push(b'\n');
    }
    output
}

fn claude_message(
    record_type: &str,
    role: &str,
    timestamp: &str,
    message_id: &str,
    model: &str,
    stop_reason: &str,
    output_tokens: i64,
    content: Value,
) -> Vec<u8> {
    serde_json::to_vec(&json!({
        "type": record_type,
        "timestamp": timestamp,
        "isSidechain": false,
        "userType": "external",
        "version": "1.2.3",
        "uuid": format!("{record_type}-{message_id}"),
        "message": {
            "id": message_id,
            "role": role,
            "model": model,
            "stop_reason": stop_reason,
            "content": content,
            "usage": { "output_tokens": output_tokens },
            "effort": "high"
        }
    }))
    .unwrap()
}

fn claude_user(timestamp: &str, id: &str, content: Value) -> Vec<u8> {
    serde_json::to_vec(&json!({
        "type":"user",
        "timestamp":timestamp,
        "isSidechain":false,
        "userType":"external",
        "uuid":id,
        "message":{"id":id,"role":"user","content":content}
    }))
    .unwrap()
}

fn grok_event(event_type: &str, values: Value) -> Vec<u8> {
    let mut event = json!({
        "type": event_type,
        "schema_version": "1.0"
    });
    for (key, value) in values.as_object().unwrap() {
        event[key] = value.clone();
    }
    serde_json::to_vec(&event).unwrap()
}

fn write_grok_session(root: &Path, name: &str, events: &[Vec<u8>], usage: &Value) -> PathBuf {
    let directory = root.join(name);
    fs::create_dir_all(&directory).unwrap();
    fs::write(directory.join("events.jsonl"), jsonl(events)).unwrap();
    fs::write(
        directory.join("usage.json"),
        serde_json::to_vec(usage).unwrap(),
    )
    .unwrap();
    directory
}

fn grok_turn_events(session_id: &str, number: u64, outcome: &str) -> Vec<Vec<u8>> {
    vec![
        grok_event(
            "turn_started",
            json!({
                "ts":"2026-10-03T10:00:00Z",
                "session_id":session_id,
                "turn_number":number,
                "model_id":"grok-4",
                "session_relationship":"primary"
            }),
        ),
        grok_event(
            "turn_ended",
            json!({"ts":"2026-10-03T10:00:05Z","outcome":outcome}),
        ),
    ]
}

fn grok_usage(session_id: &str, number: u64, output_tokens: i64) -> Value {
    json!({
        "sessionId":session_id,
        "updatedAt":"2026-10-03T10:00:05Z",
        "session":{},
        "turns":[{
            "turnNumber":number + 1,
            "endedAt":"2026-10-03T10:00:05Z",
            "outputTokens":output_tokens,
            "reasoningTokens":10,
            "modelCalls":1,
            "usageIsIncomplete":false,
            "primaryModelId":"grok-4",
            "modelUsage":{"grok-4":{"outputTokens":output_tokens}}
        }]
    })
}

#[test]
fn parser_uses_latest_cumulative_tokens_and_keeps_effort_conflicts_unknown() {
    let mut parser = crate::parser::CodexEventParser::new("private-session-path".into());
    let timestamp = "2026-10-03T10:00:00Z";
    let meta = event(
        "session_meta",
        json!({
            "id": "sensitive-session-id",
            "source": "vscode",
            "model_provider": "openai",
            "cli_version": "0.159.2",
            "effort": "ultra",
            "account_id": "private-account",
        }),
        timestamp,
    );
    assert!(parser.consume(&meta).is_none());
    parser.consume(&event(
        "turn_context",
        json!({ "turn_id": "sensitive-turn", "model": "gpt-test", "effort": "high" }),
        timestamp,
    ));
    parser.consume(&event(
        "turn_context",
        json!({ "turn_id": "sensitive-turn", "model": "gpt-test", "effort": "low" }),
        timestamp,
    ));
    parser.consume(&event("token_usage_record", json!({ "turn_id": "sensitive-turn", "turn_token_usage": { "output_tokens": 8, "reasoning_output_tokens": 2 } }), timestamp));
    parser.consume(&event("token_usage_record", json!({ "turn_id": "sensitive-turn", "turn_token_usage": { "output_tokens": 13, "reasoning_output_tokens": 4 } }), timestamp));
    parser.consume(&event(
        "event_msg",
        json!({ "type": "task_started", "turn_id": "sensitive-turn", "started_at": timestamp }),
        timestamp,
    ));
    let complete = event(
        "event_msg",
        json!({
            "type": "task_complete",
            "turn_id": "sensitive-turn",
            "started_at": timestamp,
            "completed_at": "2026-10-03T10:00:02Z",
            "duration_ms": null,
            "time_to_first_token_ms": 500,
            "last_agent_message": "private prompt and response",
        }),
        "2026-10-03T10:00:02Z",
    );
    let parsed = parser.consume(&complete).unwrap();
    assert_eq!(parsed.output_tokens, 13);
    assert_eq!(parsed.reasoning_output_tokens, Some(4));
    assert_eq!(parsed.duration_seconds, 2.0);
    assert_eq!(parsed.turn_throughput_tps, 6.5);
    assert_eq!(parsed.codex_ttft_seconds, Some(0.5));
    assert_eq!(parsed.model.as_deref(), Some("gpt-test"));
    assert_eq!(parsed.reasoning_effort, None);
    assert_eq!(parsed.client_version.as_deref(), Some("0.159.2"));
    assert_eq!(parsed.source_kind.as_deref(), Some("primary"));
    assert_eq!(parsed.provider.as_deref(), Some("openai"));
    assert!(parser.consume(&complete).is_none());

    let json = serde_json::to_string(&parsed).unwrap();
    assert_eq!(parsed.id.len(), 64);
    assert!(json.contains("\"turnThroughputTPS\""));
    assert!(json.contains("\"codexTTFTSeconds\""));
    assert!(json.contains("\"streamingTPS\""));
    for secret in [
        "private-session-path",
        "sensitive-session-id",
        "sensitive-turn",
        "private-account",
        "private prompt",
    ] {
        assert!(!json.contains(secret));
    }
    assert!(!ReportedReasoningEffort::is_allowed("automatic"));
}

#[test]
fn parser_rejects_subagents_ambiguous_models_and_invalid_counters() {
    let now = "2026-10-03T10:00:00Z";
    let mut agent = crate::parser::CodexEventParser::new("agent-file".into());
    agent.consume(&event(
        "session_meta",
        json!({ "source": { "subagent": null } }),
        now,
    ));
    agent.consume(&event(
        "token_usage_record",
        json!({ "turn_id": "t", "turn_token_usage": { "output_tokens": 20 } }),
        now,
    ));
    assert!(agent
        .consume(&event(
            "event_msg",
            json!({ "type": "task_complete", "turn_id": "t", "duration_ms": 1000 }),
            now
        ))
        .is_none());

    let mut ambiguous = crate::parser::CodexEventParser::new("file".into());
    ambiguous.consume(&event(
        "event_msg",
        json!({ "type": "task_started", "turn_id": "t", "started_at": now }),
        now,
    ));
    ambiguous.consume(&event(
        "turn_context",
        json!({ "turn_id": "t", "model": "one", "effort": "high" }),
        now,
    ));
    ambiguous.consume(&event(
        "turn_context",
        json!({ "turn_id": "t", "model": "two", "effort": "high" }),
        now,
    ));
    ambiguous.consume(&event(
        "token_usage_record",
        json!({ "turn_id": "t", "turn_token_usage": { "output_tokens": 3 } }),
        now,
    ));
    let result = ambiguous.consume(&event("event_msg", json!({ "type": "task_complete", "turn_id": "t", "started_at": now, "completed_at": "2026-10-03T10:00:01Z", "duration_ms": -5 }), "2026-10-03T10:00:01Z")).unwrap();
    assert_eq!(result.model, None);
    assert_eq!(result.reasoning_effort.as_deref(), Some("high"));

    let mut malformed = crate::parser::CodexEventParser::new("file".into());
    malformed.consume(&event(
        "token_usage_record",
        json!({ "turn_id": "t", "turn_token_usage": { "output_tokens": true } }),
        now,
    ));
    assert!(malformed.consume(&event("event_msg", json!({ "type": "task_complete", "turn_id": "t", "started_at": now, "completed_at": "2026-10-03T10:00:01Z", "duration_ms": 1000 }), "2026-10-03T10:00:01Z")).is_none());
}

#[test]
fn claude_transcript_deduplicates_api_messages_skips_tool_users_and_omits_content() {
    let mut parser = crate::claude_parser::ClaudeTranscriptParser::new("private/path.jsonl".into());
    let start = "2026-10-03T10:00:00Z";
    let tool = "2026-10-03T10:00:02Z";
    let end = "2026-10-03T10:00:04Z";
    parser.consume_settled(&claude_user(
        start,
        "human-1",
        json!("SYNTHETIC_PROMPT_SENTINEL"),
    ));
    parser.consume_settled(&claude_message(
        "assistant",
        "assistant",
        tool,
        "api-message-1",
        "claude-opus-4-1",
        "tool_use",
        2,
        json!([{"type":"thinking","thinking":"SYNTHETIC_PRIVATE_SENTINEL"}]),
    ));
    // Claude stores tool output in a user-shaped transcript record. It is not a new turn.
    parser.consume_settled(&claude_user(
        tool,
        "tool-result",
        json!([{"type":"tool_result","content":"SYNTHETIC_TOOL_SENTINEL"}]),
    ));
    // A repeated API message ID is an update to that message's cumulative usage.
    parser.consume_settled(&claude_message(
        "assistant",
        "assistant",
        tool,
        "api-message-1",
        "claude-opus-4-1",
        "tool_use",
        3,
        json!([{"type":"text","text":"SYNTHETIC_RESPONSE_SENTINEL"}]),
    ));
    let mut terminal = claude_message(
        "assistant",
        "assistant",
        end,
        "api-message-2",
        "claude-opus-4-1",
        "end_turn",
        4,
        json!([{"type":"text","text":"not summed separately"}]),
    );
    let mut value: Value = serde_json::from_slice(&terminal).unwrap();
    value["effort"] = json!("high");
    terminal = serde_json::to_vec(&value).unwrap();
    let result = parser.consume_settled(&terminal).unwrap();
    assert_eq!(result.output_tokens, 7);
    assert_eq!(result.duration_seconds, 4.0);
    assert_eq!(result.turn_throughput_tps, 1.75);
    assert_eq!(result.model.as_deref(), Some("claude-opus-4-1"));
    assert_eq!(result.reasoning_effort.as_deref(), Some("high"));
    assert_eq!(result.provider.as_deref(), Some("unknown"));
    assert_eq!(result.codex_ttft_seconds, None);
    assert_eq!(result.client_version.as_deref(), Some("1.2.3"));
    assert_eq!(result.client, CLAUDE_CLIENT);
    assert_eq!(result.parser_version, CLAUDE_PARSER_VERSION);
    assert_eq!(result.metric_version, CLAUDE_METRIC_VERSION);
    let normalized = serde_json::to_string(&result).unwrap();
    for secret in [
        "SYNTHETIC_PROMPT_SENTINEL",
        "SYNTHETIC_PRIVATE_SENTINEL",
        "SYNTHETIC_TOOL_SENTINEL",
        "SYNTHETIC_RESPONSE_SENTINEL",
        "private/path.jsonl",
    ] {
        assert!(!normalized.contains(secret));
    }
}

#[test]
fn claude_fails_closed_for_interjections_model_or_effort_conflicts_and_sidechains() {
    let t0 = "2026-10-03T10:00:00Z";
    let t1 = "2026-10-03T10:00:01Z";
    let t2 = "2026-10-03T10:00:02Z";
    let user = |id: &str, at: &str| claude_user(at, id, json!("synthetic"));
    let mut interjection = crate::claude_parser::ClaudeTranscriptParser::new("file".into());
    interjection.consume_settled(&user("first", t0));
    interjection.consume_settled(&claude_message(
        "assistant",
        "assistant",
        t1,
        "call-1",
        "claude-model",
        "tool_use",
        2,
        json!([]),
    ));
    interjection.consume_settled(&user("interjection", t1));
    // A message typed mid-turn continues the turn instead of failing it closed.
    let continued = interjection
        .consume_settled(&claude_message(
            "assistant",
            "assistant",
            t2,
            "call-2",
            "claude-model",
            "end_turn",
            2,
            json!([]),
        ))
        .unwrap();
    assert_eq!(continued.output_tokens, 4);
    assert_eq!(continued.duration_seconds, 2.0);
    interjection.consume_settled(&user("next-turn", t1));
    assert!(interjection
        .consume_settled(&claude_message(
            "assistant",
            "assistant",
            t2,
            "call-3",
            "claude-model",
            "end_turn",
            2,
            json!([])
        ))
        .is_some());

    let mut mixed_model = crate::claude_parser::ClaudeTranscriptParser::new("file".into());
    mixed_model.consume_settled(&user("model-conflict", t0));
    mixed_model.consume_settled(&claude_message(
        "assistant",
        "assistant",
        t1,
        "call-1",
        "claude-model-a",
        "tool_use",
        2,
        json!([]),
    ));
    let unknown = mixed_model
        .consume_settled(&claude_message(
            "assistant",
            "assistant",
            t2,
            "call-2",
            "claude-model-b",
            "end_turn",
            3,
            json!([]),
        ))
        .unwrap();
    assert_eq!(unknown.model, None);

    let mut conflict = crate::claude_parser::ClaudeTranscriptParser::new("file".into());
    conflict.consume_settled(&user("effort-conflict", t0));
    let mut high = claude_message(
        "assistant",
        "assistant",
        t1,
        "call-1",
        "claude-model",
        "tool_use",
        2,
        json!([]),
    );
    let mut value: Value = serde_json::from_slice(&high).unwrap();
    value["message"]["effort"] = json!("high");
    high = serde_json::to_vec(&value).unwrap();
    conflict.consume_settled(&high);
    let mut low = claude_message(
        "assistant",
        "assistant",
        t2,
        "call-2",
        "claude-model",
        "end_turn",
        3,
        json!([]),
    );
    let mut value: Value = serde_json::from_slice(&low).unwrap();
    value["message"]["effort"] = json!("low");
    low = serde_json::to_vec(&value).unwrap();
    let unknown_effort = conflict.consume_settled(&low).unwrap();
    assert_eq!(unknown_effort.reasoning_effort, None);

    let mut sidechain = crate::claude_parser::ClaudeTranscriptParser::new("file".into());
    sidechain.consume_settled(
        &serde_json::to_vec(
            &json!({"type":"assistant","isSidechain":true,"message":{"role":"assistant"}}),
        )
        .unwrap(),
    );
    assert!(!sidechain.excludes_session());
    sidechain.consume_settled(&claude_user(
        t0,
        "primary-after-sidechain",
        json!("synthetic"),
    ));
    assert!(sidechain
        .consume_settled(&claude_message(
            "assistant",
            "assistant",
            t1,
            "primary-after-sidechain-call",
            "claude-model",
            "end_turn",
            2,
            json!([]),
        ))
        .is_some());
}

#[test]
fn claude_requires_primary_flags_complete_usage_and_monotonic_snapshots() {
    let t0 = "2026-10-03T10:00:00Z";
    let t1 = "2026-10-03T10:00:01Z";
    let t2 = "2026-10-03T10:00:02Z";

    let mut missing_primary = crate::claude_parser::ClaudeTranscriptParser::new("file".into());
    let mut user: Value =
        serde_json::from_slice(&claude_user(t0, "missing-flags", json!("x"))).unwrap();
    user.as_object_mut().unwrap().remove("isSidechain");
    missing_primary.consume_settled(&serde_json::to_vec(&user).unwrap());
    assert!(missing_primary
        .consume_settled(&claude_message(
            "assistant",
            "assistant",
            t1,
            "call-missing-flags",
            "claude-model",
            "end_turn",
            5,
            json!([]),
        ))
        .is_none());

    let mut agent = crate::claude_parser::ClaudeTranscriptParser::new("file".into());
    let mut user: Value =
        serde_json::from_slice(&claude_user(t0, "agent-user", json!("x"))).unwrap();
    user["agentId"] = json!("nested-agent");
    agent.consume_settled(&serde_json::to_vec(&user).unwrap());
    assert!(agent
        .consume_settled(&claude_message(
            "assistant",
            "assistant",
            t1,
            "agent-call",
            "claude-model",
            "end_turn",
            5,
            json!([]),
        ))
        .is_none());

    let mut missing_usage = crate::claude_parser::ClaudeTranscriptParser::new("file".into());
    missing_usage.consume_settled(&claude_user(t0, "missing-usage", json!("x")));
    let mut first: Value = serde_json::from_slice(&claude_message(
        "assistant",
        "assistant",
        t1,
        "call-no-usage",
        "claude-model",
        "tool_use",
        4,
        json!([]),
    ))
    .unwrap();
    first["message"].as_object_mut().unwrap().remove("usage");
    missing_usage.consume_settled(&serde_json::to_vec(&first).unwrap());
    assert!(missing_usage
        .consume_settled(&claude_message(
            "assistant",
            "assistant",
            t2,
            "call-terminal",
            "claude-model",
            "end_turn",
            3,
            json!([]),
        ))
        .is_none());

    let mut decreasing = crate::claude_parser::ClaudeTranscriptParser::new("file".into());
    decreasing.consume_settled(&claude_user(t0, "decreasing-usage", json!("x")));
    decreasing.consume_settled(&claude_message(
        "assistant",
        "assistant",
        t1,
        "same-api-message",
        "claude-model",
        "tool_use",
        4,
        json!([]),
    ));
    assert!(decreasing
        .consume_settled(&claude_message(
            "assistant",
            "assistant",
            t2,
            "same-api-message",
            "claude-model",
            "end_turn",
            3,
            json!([]),
        ))
        .is_none());

    let mut modelless = crate::claude_parser::ClaudeTranscriptParser::new("file".into());
    modelless.consume_settled(&claude_user(t0, "modelless", json!("x")));
    let unknown = modelless
        .consume_settled(&claude_message(
            "assistant",
            "assistant",
            t1,
            "modelless-call",
            "",
            "end_turn",
            5,
            json!([]),
        ))
        .unwrap();
    assert_eq!(unknown.model, None);
}

fn with_fields(line: Vec<u8>, fields: Value) -> Vec<u8> {
    let mut value: Value = serde_json::from_slice(&line).unwrap();
    for (key, field) in fields.as_object().unwrap() {
        value[key] = field.clone();
    }
    serde_json::to_vec(&value).unwrap()
}

fn as_subagent(line: Vec<u8>, session: &str, agent: &str) -> Vec<u8> {
    with_fields(
        line,
        json!({"isSidechain": true, "sessionId": session, "agentId": agent}),
    )
}

fn assistant(timestamp: &str, id: &str, stop_reason: &str, tokens: i64) -> Vec<u8> {
    claude_message(
        "assistant",
        "assistant",
        timestamp,
        id,
        "claude-model",
        stop_reason,
        tokens,
        json!([]),
    )
}

fn poll_until_idle(monitor: &mut Monitor, now: DateTime<Utc>) -> Vec<TurnMetric> {
    let mut found = Vec::new();
    for _ in 0..4 {
        found.extend(monitor.poll(now).unwrap());
    }
    found
}

fn claude_parser() -> crate::claude_parser::ClaudeTranscriptParser {
    crate::claude_parser::ClaudeTranscriptParser::new("file".into())
}

#[test]
fn claude_interjection_continues_one_turn_from_its_original_start() {
    let human = |id: &str, at: &str| claude_user(at, id, json!("synthetic"));
    let mut plain = claude_parser();
    plain.consume_settled(&human("turn", "2026-10-03T10:00:00Z"));
    plain.consume_settled(&assistant("2026-10-03T10:00:10Z", "call-1", "tool_use", 5));
    let baseline = plain
        .consume_settled(&assistant("2026-10-03T10:00:40Z", "call-2", "end_turn", 7))
        .unwrap();

    let mut parser = claude_parser();
    parser.consume_settled(&human("turn", "2026-10-03T10:00:00Z"));
    parser.consume_settled(&assistant("2026-10-03T10:00:10Z", "call-1", "tool_use", 5));
    parser.consume_settled(&human("typed-while-working", "2026-10-03T10:00:20Z"));
    parser.consume_settled(&assistant("2026-10-03T10:00:30Z", "call-1b", "tool_use", 3));
    let result = parser
        .consume_settled(&assistant("2026-10-03T10:00:40Z", "call-2", "end_turn", 7))
        .unwrap();
    assert_eq!(result.output_tokens, 15);
    assert_eq!(result.duration_seconds, 40.0);
    assert_eq!(result.turn_throughput_tps, 15.0 / 40.0);
    assert_eq!(result.model.as_deref(), Some("claude-model"));
    assert_eq!(result.reasoning_effort.as_deref(), Some("high"));
    assert_eq!(result.client_version.as_deref(), Some("1.2.3"));
    assert_eq!(result.parser_version, "claude-transcript-v4");
    assert_eq!(result.metric_version, CLAUDE_METRIC_VERSION);
    assert_eq!(result.source_kind.as_deref(), Some("primary"));
    // Identity comes from the original human turn, so an interjection never changes it.
    assert_eq!(result.id, baseline.id);
}

#[test]
fn claude_interjection_gap_over_thirty_minutes_starts_a_new_turn() {
    let human = |id: &str, at: &str| claude_user(at, id, json!("synthetic"));
    let mut parser = claude_parser();
    parser.consume_settled(&human("old", "2026-10-03T10:00:00Z"));
    parser.consume_settled(&assistant("2026-10-03T10:00:10Z", "call-1", "tool_use", 5));
    // 30 minutes after the last activity still continues the turn.
    parser.consume_settled(&human("boundary", "2026-10-03T10:30:10Z"));
    parser.consume_settled(&assistant("2026-10-03T10:30:20Z", "call-2", "tool_use", 4));
    // More than 30 minutes later the old turn is abandoned and a new one starts.
    parser.consume_settled(&human("new", "2026-10-03T11:00:21Z"));
    let result = parser
        .consume_settled(&assistant("2026-10-03T11:00:41Z", "call-3", "end_turn", 40))
        .unwrap();
    assert_eq!(result.output_tokens, 40);
    assert_eq!(result.duration_seconds, 20.0);

    let mut continued = claude_parser();
    continued.consume_settled(&human("old", "2026-10-03T10:00:00Z"));
    continued.consume_settled(&assistant("2026-10-03T10:00:10Z", "call-1", "tool_use", 5));
    continued.consume_settled(&human("boundary", "2026-10-03T10:30:10Z"));
    let whole = continued
        .consume_settled(&assistant("2026-10-03T10:30:20Z", "call-2", "end_turn", 4))
        .unwrap();
    assert_eq!(whole.output_tokens, 9);
    assert_eq!(whole.duration_seconds, 1820.0);
}

#[test]
fn claude_tool_results_count_as_activity_for_long_tool_runs() {
    let mut parser = claude_parser();
    parser.consume_settled(&claude_user(
        "2026-10-03T10:00:00Z",
        "prompt",
        json!("synthetic"),
    ));
    parser.consume_settled(&assistant("2026-10-03T10:01:00Z", "call-1", "tool_use", 5));
    // The tool ran for 39 minutes; its result is activity and never starts a turn.
    parser.consume_settled(&claude_user(
        "2026-10-03T10:40:00Z",
        "tool-result",
        json!([{"type":"tool_result","content":"SYNTHETIC_TOOL_SENTINEL"}]),
    ));
    parser.consume_settled(&claude_user(
        "2026-10-03T10:41:00Z",
        "typed-after-tool",
        json!("synthetic"),
    ));
    let result = parser
        .consume_settled(&assistant("2026-10-03T10:42:00Z", "call-2", "end_turn", 7))
        .unwrap();
    assert_eq!(result.output_tokens, 12);
    assert_eq!(result.duration_seconds, 2520.0);

    let mut orphan = claude_parser();
    orphan.consume_settled(&claude_user(
        "2026-10-03T10:00:00Z",
        "orphan-result",
        json!([{"type":"tool_result","content":"x"}]),
    ));
    assert!(orphan
        .consume_settled(&assistant("2026-10-03T10:00:05Z", "call", "end_turn", 9))
        .is_none());
}

#[test]
fn claude_user_records_without_a_timestamp_are_ignored_entirely() {
    let mut parser = claude_parser();
    parser.consume_settled(&claude_user(
        "2026-10-03T10:00:00Z",
        "prompt",
        json!("synthetic"),
    ));
    parser.consume_settled(&assistant("2026-10-03T10:00:05Z", "call-1", "tool_use", 5));
    let without_time = |content: Value| {
        let mut value: Value =
            serde_json::from_slice(&claude_user("2026-10-03T10:00:06Z", "no-time", content))
                .unwrap();
        value.as_object_mut().unwrap().remove("timestamp");
        serde_json::to_vec(&value).unwrap()
    };
    // Neither a human prompt nor an interruption marker without a time touches the turn.
    parser.consume_settled(&without_time(json!("synthetic")));
    parser.consume_settled(&without_time(json!("[Request interrupted by user]")));
    let result = parser
        .consume_settled(&assistant("2026-10-03T10:00:10Z", "call-2", "end_turn", 7))
        .unwrap();
    assert_eq!(result.output_tokens, 12);
    assert_eq!(result.duration_seconds, 10.0);

    let mut idle = claude_parser();
    idle.consume_settled(&without_time(json!("synthetic")));
    assert!(idle
        .consume_settled(&assistant("2026-10-03T10:00:10Z", "call", "end_turn", 9))
        .is_none());
}

#[test]
fn claude_interruption_discards_the_turn_and_does_not_start_one() {
    let human = |id: &str, at: &str| claude_user(at, id, json!("synthetic"));
    for marker in [
        json!("[Request interrupted by user]"),
        json!([{"type":"text","text":"[Request interrupted by user for tool use]"}]),
    ] {
        let mut parser = claude_parser();
        parser.consume_settled(&human("interrupted", "2026-10-03T10:00:00Z"));
        parser.consume_settled(&assistant("2026-10-03T10:00:05Z", "call-1", "tool_use", 5));
        parser.consume_settled(&claude_user("2026-10-03T10:00:06Z", "marker", marker));
        // The marker did not start a turn, so the trailing answer has nothing to attach to.
        assert!(parser
            .consume_settled(&assistant("2026-10-03T10:00:10Z", "call-2", "end_turn", 9))
            .is_none());
        parser.consume_settled(&human("after", "2026-10-03T10:01:00Z"));
        let result = parser
            .consume_settled(&assistant("2026-10-03T10:01:10Z", "call-3", "end_turn", 20))
            .unwrap();
        assert_eq!(result.output_tokens, 20);
        assert_eq!(result.duration_seconds, 10.0);
    }
}

#[test]
fn claude_synthetic_messages_invalidate_the_turn_without_model_ambiguity() {
    let human = |id: &str, at: &str| claude_user(at, id, json!("synthetic"));
    let synthetic = |at: &str, id: &str, stop: &str| {
        claude_message(
            "assistant",
            "assistant",
            at,
            id,
            "<synthetic>",
            stop,
            0,
            json!([]),
        )
    };
    let mut only = claude_parser();
    only.consume_settled(&human("synthetic-only", "2026-10-03T10:00:00Z"));
    assert!(only
        .consume_settled(&synthetic("2026-10-03T10:00:02Z", "s1", "end_turn"))
        .is_none());

    let mut mixed = claude_parser();
    mixed.consume_settled(&human("synthetic-mixed", "2026-10-03T10:00:00Z"));
    mixed.consume_settled(&assistant("2026-10-03T10:00:01Z", "real-1", "tool_use", 5));
    mixed.consume_settled(&synthetic("2026-10-03T10:00:02Z", "s2", "tool_use"));
    assert!(mixed
        .consume_settled(&assistant("2026-10-03T10:00:03Z", "real-2", "end_turn", 6))
        .is_none());

    // The invalid turn is cleared at its terminal message; later turns are unaffected.
    mixed.consume_settled(&human("clean", "2026-10-03T10:01:00Z"));
    let clean = mixed
        .consume_settled(&assistant("2026-10-03T10:01:10Z", "real-3", "end_turn", 30))
        .unwrap();
    assert_eq!(clean.model.as_deref(), Some("claude-model"));
    assert_eq!(clean.output_tokens, 30);
}

#[test]
fn claude_meta_user_records_neither_start_nor_interrupt_turns() {
    let human = |id: &str, at: &str| claude_user(at, id, json!("synthetic"));
    let meta = |id: &str, at: &str| {
        with_fields(
            claude_user(at, id, json!("synthetic caveat")),
            json!({"isMeta": true}),
        )
    };
    let mut starts = claude_parser();
    starts.consume_settled(&meta("meta-start", "2026-10-03T10:00:00Z"));
    assert!(starts
        .consume_settled(&assistant("2026-10-03T10:00:05Z", "call-1", "end_turn", 9))
        .is_none());

    // A meta record far past the continuation window must not replace the active turn.
    let mut meta_interrupt = claude_parser();
    meta_interrupt.consume_settled(&human("kept", "2026-10-03T10:00:00Z"));
    meta_interrupt.consume_settled(&with_fields(
        claude_user(
            "2026-10-03T10:00:01Z",
            "meta-interrupt",
            json!("[Request interrupted by user]"),
        ),
        json!({"isMeta": true}),
    ));
    assert!(meta_interrupt
        .consume_settled(&assistant("2026-10-03T10:00:05Z", "call", "end_turn", 9))
        .is_some());

    let mut active = claude_parser();
    active.consume_settled(&human("real", "2026-10-03T10:00:00Z"));
    active.consume_settled(&assistant("2026-10-03T10:00:01Z", "call-1", "tool_use", 5));
    active.consume_settled(&meta("meta-later", "2026-10-03T10:45:00Z"));
    let result = active
        .consume_settled(&assistant("2026-10-03T10:45:10Z", "call-2", "end_turn", 7))
        .unwrap();
    assert_eq!(result.output_tokens, 12);
    assert_eq!(result.duration_seconds, 2710.0);
}

#[test]
fn claude_subagent_parser_emits_distinct_subagent_metrics_and_each_prompt_is_a_turn() {
    let session = "11111111-2222-4333-8444-555555555555";
    let agent = "a1b2c3d4e5f60718";
    let user = |id: &str, at: &str| {
        as_subagent(
            claude_user(at, id, json!("synthetic task prompt")),
            session,
            agent,
        )
    };
    let reply = |at: &str, id: &str, stop: &str, tokens: i64| {
        as_subagent(assistant(at, id, stop, tokens), session, agent)
    };
    let mut parser = crate::claude_parser::ClaudeTranscriptParser::new_subagent("file".into());
    parser.consume_settled(&user("task-1", "2026-10-03T10:00:00Z"));
    parser.consume_settled(&reply("2026-10-03T10:00:04Z", "sub-call-1", "tool_use", 10));
    let first = parser
        .consume_settled(&reply("2026-10-03T10:00:10Z", "sub-call-2", "end_turn", 30))
        .unwrap();
    assert_eq!(first.client, CLAUDE_CLIENT);
    assert_eq!(first.parser_version, "claude-transcript-v4");
    assert_eq!(first.metric_version, CLAUDE_SUBAGENT_METRIC_VERSION);
    assert_eq!(first.source_kind.as_deref(), Some("subagent"));
    assert_eq!(first.provider.as_deref(), Some("unknown"));
    assert_eq!(first.codex_ttft_seconds, None);
    assert_eq!(first.streaming_tps, None);
    assert_eq!(first.reasoning_effort.as_deref(), Some("high"));
    assert_eq!(first.output_tokens, 40);
    assert_eq!(first.duration_seconds, 10.0);
    use sha2::{Digest, Sha256};
    assert_eq!(
        first.id,
        format!(
            "{:x}",
            Sha256::digest(format!("{session}|{agent}|task-1").as_bytes())
        ),
        "the subagent identity is sessionId|agentId|user turn uuid"
    );

    // A later follow-up prompt that ends in another final answer is a separate turn.
    parser.consume_settled(&user("task-2", "2026-10-03T10:05:00Z"));
    let second = parser
        .consume_settled(&reply("2026-10-03T10:05:20Z", "sub-call-3", "end_turn", 60))
        .unwrap();
    assert_eq!(second.output_tokens, 60);
    assert_eq!(second.duration_seconds, 20.0);
    assert_ne!(second.id, first.id);

    // The same records measured as primary produce nothing, and the reverse holds too.
    let mut primary = claude_parser();
    primary.consume_settled(&user("task-1", "2026-10-03T10:00:00Z"));
    assert!(primary
        .consume_settled(&reply("2026-10-03T10:00:10Z", "sub-call-2", "end_turn", 30))
        .is_none());
    let mut subagent = crate::claude_parser::ClaudeTranscriptParser::new_subagent("file".into());
    subagent.consume_settled(&claude_user(
        "2026-10-03T10:00:00Z",
        "primary-turn",
        json!("synthetic"),
    ));
    assert!(subagent
        .consume_settled(&assistant(
            "2026-10-03T10:00:10Z",
            "primary-call",
            "end_turn",
            30
        ))
        .is_none());

    // Primary identity is unaffected by the subagent scheme.
    let mut primary = claude_parser();
    primary.consume_settled(&claude_user(
        "2026-10-03T10:00:00Z",
        "task-1",
        json!("synthetic"),
    ));
    let primary = primary
        .consume_settled(&assistant(
            "2026-10-03T10:00:10Z",
            "sub-call-2",
            "end_turn",
            30,
        ))
        .unwrap();
    assert_ne!(primary.id, first.id);
    assert_eq!(primary.metric_version, CLAUDE_METRIC_VERSION);
}

#[test]
fn claude_subagent_parser_rejects_unsafe_or_mismatched_agent_identity() {
    let user = |agent: Option<&str>| {
        let mut line = as_subagent(
            claude_user("2026-10-03T10:00:00Z", "task", json!("synthetic")),
            "session-1",
            "agent-ok",
        );
        let mut value: Value = serde_json::from_slice(&line).unwrap();
        match agent {
            Some(agent) => value["agentId"] = json!(agent),
            None => {
                value.as_object_mut().unwrap().remove("agentId");
            }
        }
        line = serde_json::to_vec(&value).unwrap();
        line
    };
    for agent in [None, Some("../escape"), Some("")] {
        let mut parser = crate::claude_parser::ClaudeTranscriptParser::new_subagent("file".into());
        parser.consume(&user(agent));
        assert!(parser
            .consume(&as_subagent(
                assistant("2026-10-03T10:00:05Z", "call", "end_turn", 9),
                "session-1",
                "agent-ok",
            ))
            .is_none());
    }
    let mut mismatch = crate::claude_parser::ClaudeTranscriptParser::new_subagent("file".into());
    mismatch.consume(&user(Some("agent-ok")));
    assert!(mismatch
        .consume(&as_subagent(
            assistant("2026-10-03T10:00:05Z", "call", "end_turn", 9),
            "session-1",
            "agent-other",
        ))
        .is_none());
}

#[test]
fn claude_monitors_measure_subagents_separately_and_primary_selection_excludes_them() {
    let temp = TestDir::new();
    let codex = temp.path().join("codex");
    let claude = temp.path().join("claude-projects");
    let grok = temp.path().join("grok-sessions");
    fs::create_dir_all(&codex).unwrap();
    fs::create_dir_all(&grok).unwrap();
    let session = "session-synthetic";
    let project = claude.join("project-a");
    let subagents = project.join(session).join("subagents");
    fs::create_dir_all(&subagents).unwrap();
    let start = "2026-10-03T10:00:00Z";
    let end = "2026-10-03T10:00:10Z";
    let with_session = |line: Vec<u8>| with_fields(line, json!({"sessionId": session}));
    fs::write(
        project.join(format!("{session}.jsonl")),
        jsonl(&[
            with_session(claude_user(start, "main-user", json!("synthetic"))),
            with_session(assistant(end, "main-call", "end_turn", 50)),
        ]),
    )
    .unwrap();
    fs::write(
        subagents.join("agent-abc123.jsonl"),
        jsonl(&[
            as_subagent(
                claude_user(start, "sub-user", json!("synthetic")),
                session,
                "abc123",
            ),
            as_subagent(
                assistant(end, "sub-call", "end_turn", 70),
                session,
                "abc123",
            ),
        ]),
    )
    .unwrap();
    // Not a subagent transcript: wrong file name and wrong directory.
    fs::write(
        subagents.join("notes.jsonl"),
        jsonl(&[
            as_subagent(claude_user(start, "x-user", json!("x")), session, "abc123"),
            as_subagent(assistant(end, "x-call", "end_turn", 888), session, "abc123"),
        ]),
    )
    .unwrap();
    fs::write(
        project.join("agent-loose.jsonl"),
        jsonl(&[
            as_subagent(claude_user(start, "y-user", json!("x")), session, "loose"),
            as_subagent(assistant(end, "y-call", "end_turn", 999), session, "loose"),
        ]),
    )
    .unwrap();

    let now = time("2026-10-03T10:00:20Z");
    let mut primary_only = Monitor::new_claude(claude.clone());
    let primary = poll_until_idle(&mut primary_only, now);
    assert_eq!(primary.len(), 1);
    assert_eq!(primary[0].source_kind.as_deref(), Some("primary"));
    assert_eq!(primary[0].output_tokens, 50);

    let mut subagent_only = Monitor::new_claude_subagents(claude.clone());
    let subagent = poll_until_idle(&mut subagent_only, now);
    assert_eq!(subagent.len(), 1);
    assert_eq!(subagent[0].source_kind.as_deref(), Some("subagent"));
    assert_eq!(subagent[0].output_tokens, 70);

    let mut monitor = SourceMonitor::new(
        codex,
        claude,
        grok,
        temp.path().join("gemini"),
        temp.path().join("opencode"),
    );
    let mut found = Vec::new();
    for _ in 0..4 {
        found.extend(monitor.poll(now).unwrap());
        assert!(monitor.bytes_read_last_poll() <= SourceMonitor::MAX_POLL_BYTES);
    }
    let mut tokens: Vec<(i64, Option<&str>, &str)> = found
        .iter()
        .map(|row| {
            (
                row.output_tokens,
                row.source_kind.as_deref(),
                row.metric_version.as_str(),
            )
        })
        .collect();
    tokens.sort();
    assert_eq!(
        tokens,
        vec![
            (50, Some("primary"), CLAUDE_METRIC_VERSION),
            (70, Some("subagent"), CLAUDE_SUBAGENT_METRIC_VERSION),
        ]
    );
    assert_ne!(found[0].id, found[1].id);
}

#[test]
fn subagent_samples_share_only_allowlisted_keys_with_the_current_app_version() {
    let mut metric = TurnMetric::new_observed(
        "local-subagent-digest".into(),
        time("2026-10-03T10:03:47Z"),
        Some("claude-sonnet-5-5".into()),
        90,
        3.0,
        Some("2.1.0".into()),
        None,
        Some("subagent".into()),
        Some("unknown".into()),
        Some("high".into()),
        CLAUDE_CLIENT,
        CLAUDE_PARSER_VERSION,
        CLAUDE_SUBAGENT_METRIC_VERSION,
    );
    let sample = crate::SharedSample::from_metric(&metric, Uuid::new_v4()).unwrap();
    assert_eq!(sample.source_kind, "subagent");
    assert_eq!(sample.app_version, "0.1.19");
    assert_eq!(sample.metric_version, "claude-observed-subagent-turn-v1");
    assert_eq!(sample.parser_version, "claude-transcript-v4");
    assert_eq!(sample.ttft_ms, None);
    // Subagent records are never attributed: the key is present and null.
    assert_eq!(sample.delegated_output_tokens, None);
    let json = serde_json::to_value(&sample).unwrap();
    assert!(json["delegatedOutputTokens"].is_null());
    let mut keys: Vec<&str> = json
        .as_object()
        .unwrap()
        .keys()
        .map(String::as_str)
        .collect();
    keys.sort();
    assert_eq!(
        keys,
        [
            "appVersion",
            "cacheReadInputTokens",
            "cacheWriteInputTokens",
            "client",
            "clientVersion",
            "delegatedOutputTokens",
            "durationMs",
            "inputTokens",
            "metricVersion",
            "model",
            "observedAt",
            "outputTokens",
            "parserVersion",
            "provider",
            "providerRegion",
            "reasoningEffort",
            "reasoningOutputTokens",
            "responseCount",
            "responseDurationMs",
            "responseOutputTokens",
            "sampleId",
            "sourceKind",
            "surface",
            "ttftMs"
        ]
    );
    assert!(!json.to_string().contains("local-subagent-digest"));

    // The new parser version is the only supported Claude definition.
    metric.parser_version = "claude-transcript-v1".into();
    assert!(crate::SharedSample::from_metric(&metric, Uuid::new_v4()).is_none());
}

#[test]
fn grok_emits_completed_turn_once_even_if_usage_snapshot_later_changes() {
    let temp = TestDir::new();
    let root = temp.path();
    write_grok_session(
        root,
        "session-private-id",
        &grok_turn_events("session-private-id", 7, "completed"),
        &grok_usage("session-private-id", 7, 50),
    );
    let now = time("2026-10-03T10:00:06Z");
    let mut monitor = GrokMonitor::new(root.to_path_buf());
    let mut found = Vec::new();
    for _ in 0..3 {
        found.extend(monitor.poll(now).unwrap());
        assert!(monitor.bytes_read_last_poll() <= GrokMonitor::MAX_POLL_BYTES);
        if !found.is_empty() {
            break;
        }
    }
    assert_eq!(found.len(), 1);
    let first = &found[0];
    assert_eq!(first.output_tokens, 50);
    assert_eq!(first.reasoning_output_tokens, Some(10));
    assert_eq!(first.duration_seconds, 5.0);
    assert_eq!(first.turn_throughput_tps, 10.0);
    assert_eq!(first.model.as_deref(), Some("grok-4"));
    assert_eq!(first.provider.as_deref(), Some("unknown"));
    assert_eq!(first.client_version, None);
    assert_eq!(first.codex_ttft_seconds, None);
    assert_eq!(first.client, GROK_CLIENT);
    assert_eq!(first.parser_version, GROK_PARSER_VERSION);
    assert_eq!(first.parser_version, "grok-session-v2");
    assert_eq!(first.metric_version, GROK_METRIC_VERSION);
    // No loop events were recorded, so there is no response timing.
    assert_eq!(first.response_output_tokens, None);
    assert_eq!(first.response_duration_seconds, None);
    assert_eq!(first.response_count, None);
    let normalized = serde_json::to_string(first).unwrap();
    assert!(!normalized.contains("session-private-id"));

    let mut history = History::default();
    history.merge(&found, now);
    let usage_path = root.join("session-private-id").join("usage.json");
    fs::write(
        &usage_path,
        serde_json::to_vec(&grok_usage("session-private-id", 7, 90)).unwrap(),
    )
    .unwrap();
    let updated = monitor.poll(now + Duration::seconds(1)).unwrap();
    assert!(updated.is_empty(), "an accepted turn is immutable");
    history.merge(&updated, now + Duration::seconds(1));
    assert_eq!(
        history.records().len(),
        1,
        "a later snapshot cannot emit a duplicate contribution"
    );
    assert_eq!(history.records()[0].output_tokens, 50);
}

#[test]
fn grok_detects_same_size_incomplete_to_complete_rewrite_with_unchanged_mtime() {
    let temp = TestDir::new();
    let root = temp.path();
    let usage_path = write_grok_session(
        root,
        "same-metadata",
        &grok_turn_events("same-metadata", 7, "completed"),
        &{
            let mut usage = grok_usage("same-metadata", 7, 50);
            usage["turns"][0]["usageIsIncomplete"] = json!(true);
            usage
        },
    )
    .join("usage.json");
    let original = fs::metadata(&usage_path).unwrap();
    let original_len = original.len();
    let original_modified = original.modified().unwrap();
    let now = time("2026-10-03T10:00:06Z");
    let mut monitor = GrokMonitor::new(root.to_path_buf());
    for _ in 0..3 {
        assert!(monitor.poll(now).unwrap().is_empty());
    }

    // Keep the JSON byte length identical while changing the completion flag.
    // The reasoning token digit compensates for `true`/`false` differing by one
    // byte. Restore the original mtime to model coarse filesystem timestamps.
    let mut usage = grok_usage("same-metadata", 7, 50);
    usage["turns"][0]["reasoningTokens"] = json!(9);
    let complete = serde_json::to_vec(&usage).unwrap();
    assert_eq!(complete.len() as u64, original_len);
    fs::write(&usage_path, complete).unwrap();
    fs::OpenOptions::new()
        .write(true)
        .open(&usage_path)
        .unwrap()
        .set_times(FileTimes::new().set_modified(original_modified))
        .unwrap();
    let rewritten = fs::metadata(&usage_path).unwrap();
    assert_eq!(rewritten.len(), original_len);
    assert_eq!(rewritten.modified().unwrap(), original_modified);

    // The metadata did not change, so only the watcher's report makes the monitor read the ledger
    // again, and then compares it by digest.
    assert!(monitor.note_changes(&changed(&[&usage_path])));
    let mut emitted = Vec::new();
    for _ in 0..3 {
        emitted.extend(monitor.poll(now + Duration::seconds(1)).unwrap());
        if !emitted.is_empty() {
            break;
        }
    }
    assert_eq!(emitted.len(), 1);
    assert_eq!(emitted[0].output_tokens, 50);
    assert_eq!(emitted[0].reasoning_output_tokens, Some(9));
}

#[test]
fn grok_rejects_incomplete_cancelled_subagent_repeated_and_colliding_turns() {
    let temp = TestDir::new();
    let root = temp.path();
    write_grok_session(
        root,
        "incomplete",
        &grok_turn_events("incomplete", 1, "completed"),
        &json!({
            "sessionId":"incomplete","updatedAt":"2026-10-03T10:00:05Z","turns":[{
                "turnNumber":2,"endedAt":"2026-10-03T10:00:05Z","outputTokens":20,
                "reasoningTokens":5,"usageIsIncomplete":true,"modelUsage":{"grok-4":{}}
            }]
        }),
    );
    write_grok_session(
        root,
        "cancelled",
        &grok_turn_events("cancelled", 2, "cancelled"),
        &grok_usage("cancelled", 2, 20),
    );
    write_grok_session(
        root,
        "subagent",
        &[
            grok_event(
                "turn_started",
                json!({"ts":"2026-10-03T10:00:00Z","session_id":"subagent","turn_number":3,"session_relationship":"subagent"}),
            ),
            grok_event(
                "turn_ended",
                json!({"ts":"2026-10-03T10:00:05Z","outcome":"completed"}),
            ),
        ],
        &grok_usage("subagent", 3, 20),
    );
    let repeated_events = [
        grok_turn_events("repeated", 4, "completed"),
        grok_turn_events("repeated", 4, "completed"),
    ]
    .concat();
    write_grok_session(
        root,
        "repeated",
        &repeated_events,
        &grok_usage("repeated", 4, 20),
    );
    write_grok_session(
        root,
        "collision",
        &grok_turn_events("collision", 5, "completed"),
        &json!({
            "sessionId":"collision","updatedAt":"2026-10-03T10:00:05Z","turns":[
                {"turnNumber":6,"endedAt":"2026-10-03T10:00:05Z","outputTokens":20,"usageIsIncomplete":false},
                {"turnNumber":6,"endedAt":"2026-10-03T10:00:05Z","outputTokens":21,"usageIsIncomplete":false}
            ]
        }),
    );
    let mut monitor = GrokMonitor::new(root.to_path_buf());
    for index in 0..5 {
        assert!(monitor
            .poll(time("2026-10-03T10:00:06Z") + Duration::seconds(index))
            .unwrap()
            .is_empty());
    }
}

#[test]
fn grok_unknowns_legacy_or_ambiguous_model_breakdowns() {
    let temp = TestDir::new();
    let root = temp.path();
    let mut legacy = grok_usage("legacy", 8, 30);
    legacy["turns"][0]
        .as_object_mut()
        .unwrap()
        .remove("modelUsage");
    write_grok_session(
        root,
        "legacy",
        &grok_turn_events("legacy", 8, "completed"),
        &legacy,
    );
    let mut mixed = grok_usage("mixed", 9, 30);
    mixed["turns"][0]["modelUsage"] = json!({"grok-4":{},"grok-3":{}});
    write_grok_session(
        root,
        "mixed",
        &grok_turn_events("mixed", 9, "completed"),
        &mixed,
    );
    let mut monitor = GrokMonitor::new(root.to_path_buf());
    let records = monitor.poll(time("2026-10-03T10:00:06Z")).unwrap();
    assert_eq!(records.len(), 2);
    assert!(records.iter().all(|record| record.model.is_none()));
}

#[test]
fn grok_requires_exact_session_binding_and_one_second_timestamp_tolerance() {
    let temp = TestDir::new();
    let root = temp.path();

    let mut missing_id = grok_usage("missing-id", 1, 20);
    missing_id.as_object_mut().unwrap().remove("sessionId");
    write_grok_session(
        root,
        "missing-id",
        &grok_turn_events("missing-id", 1, "completed"),
        &missing_id,
    );

    write_grok_session(
        root,
        "mismatched-id",
        &grok_turn_events("mismatched-id", 2, "completed"),
        &grok_usage("another-session", 2, 20),
    );

    let mut outside_tolerance = grok_usage("outside-tolerance", 3, 20);
    outside_tolerance["turns"][0]["endedAt"] = json!("2026-10-03T10:00:06.001Z");
    write_grok_session(
        root,
        "outside-tolerance",
        &grok_turn_events("outside-tolerance", 3, "completed"),
        &outside_tolerance,
    );

    let mut monitor = GrokMonitor::new(root.to_path_buf());
    assert!(monitor
        .poll(time("2026-10-03T10:00:07Z"))
        .unwrap()
        .is_empty());
}

#[test]
fn grok_accepts_delayed_ledger_writes_but_enforces_persistence_chronology() {
    let temp = TestDir::new();
    let root = temp.path();

    let mut delayed = grok_usage("delayed", 10, 20);
    delayed["updatedAt"] = json!("2026-10-03T10:00:15Z");
    delayed["turns"][0]["endedAt"] = json!("2026-10-03T10:00:15Z");
    write_grok_session(
        root,
        "delayed",
        &grok_turn_events("delayed", 10, "completed"),
        &delayed,
    );

    let mut too_late = grok_usage("too-late", 11, 20);
    too_late["updatedAt"] = json!("2026-10-03T10:01:06Z");
    too_late["turns"][0]["endedAt"] = json!("2026-10-03T10:01:06Z");
    write_grok_session(
        root,
        "too-late",
        &grok_turn_events("too-late", 11, "completed"),
        &too_late,
    );

    let mut updated_after_row = grok_usage("updated-after-row", 15, 20);
    updated_after_row["updatedAt"] = json!("2026-10-03T10:00:05Z");
    updated_after_row["turns"][0]["endedAt"] = json!("2026-10-03T10:00:07Z");
    write_grok_session(
        root,
        "updated-after-row",
        &grok_turn_events("updated-after-row", 15, "completed"),
        &updated_after_row,
    );

    let mut crossing_events = grok_turn_events("crossing", 12, "completed");
    crossing_events.push(grok_event(
        "turn_started",
        json!({
            "ts":"2026-10-03T10:00:10Z",
            "session_id":"crossing",
            "turn_number":13,
            "model_id":"grok-4",
            "session_relationship":"primary"
        }),
    ));
    let mut crossing = grok_usage("crossing", 12, 20);
    crossing["updatedAt"] = json!("2026-10-03T10:00:15Z");
    crossing["turns"][0]["endedAt"] = json!("2026-10-03T10:00:15Z");
    write_grok_session(root, "crossing", &crossing_events, &crossing);

    let mut mismatched_end_events = grok_turn_events("mismatched-end", 14, "completed");
    let mut end: Value = serde_json::from_slice(&mismatched_end_events[1]).unwrap();
    end["session_id"] = json!("different-session");
    mismatched_end_events[1] = serde_json::to_vec(&end).unwrap();
    write_grok_session(
        root,
        "mismatched-end",
        &mismatched_end_events,
        &grok_usage("mismatched-end", 14, 20),
    );

    let mut monitor = GrokMonitor::new(root.to_path_buf());
    let records = monitor.poll(time("2026-10-03T10:00:16Z")).unwrap();
    assert_eq!(records.len(), 1);
    assert_eq!(records[0].output_tokens, 20);
    assert_eq!(records[0].duration_seconds, 5.0);
}

#[test]
fn recent_monitor_waits_for_partial_lines_and_enforces_poll_budget() {
    let temp = TestDir::new();
    let session = temp.path().join("session.jsonl");
    let base = Utc::now();
    let completed =
        (base - Duration::seconds(2)).to_rfc3339_opts(chrono::SecondsFormat::Secs, true);
    let started = (base - Duration::seconds(3)).to_rfc3339_opts(chrono::SecondsFormat::Secs, true);
    let header = event(
        "session_meta",
        json!({ "id": "session", "source": "cli", "model_provider": "openai" }),
        &started,
    );
    let usage = event(
        "token_usage_record",
        json!({ "turn_id": "turn", "turn_token_usage": { "output_tokens": 42 } }),
        &started,
    );
    let task_started = event(
        "event_msg",
        json!({ "type": "task_started", "turn_id": "turn", "started_at": started }),
        &started,
    );
    let completion = event(
        "event_msg",
        json!({ "type": "task_complete", "turn_id": "turn", "started_at": started, "completed_at": completed, "duration_ms": 1000 }),
        &completed,
    );
    let mut contents = jsonl(&[header, task_started, usage]);
    contents.extend_from_slice(&completion);
    fs::write(&session, contents).unwrap();

    let mut monitor = Monitor::new(temp.path().to_path_buf());
    let mut records = monitor.poll(base).unwrap();
    for index in 0..10 {
        assert!(monitor.bytes_read_last_poll() <= Monitor::MAX_POLL_BYTES);
        if !records.is_empty() {
            break;
        }
        records = monitor.poll(base + Duration::seconds(11 + index)).unwrap();
    }
    assert!(
        records.is_empty(),
        "unterminated completion lines must not be parsed"
    );

    let mut append = fs::OpenOptions::new().append(true).open(&session).unwrap();
    append.write_all(b"\n").unwrap();
    // A caught-up file is read again once the watcher reports its write.
    assert!(monitor.note_changes(&changed(&[&session])));
    for index in 0..10 {
        records = monitor.poll(base + Duration::seconds(30 + index)).unwrap();
        assert!(monitor.bytes_read_last_poll() <= Monitor::MAX_POLL_BYTES);
        if !records.is_empty() {
            break;
        }
    }
    assert_eq!(records.len(), 1);
    assert_eq!(records[0].output_tokens, 42);
}

#[test]
fn monitor_reads_an_old_caught_up_tail_only_after_the_watcher_reports_its_append() {
    let temp = TestDir::new();
    let base = Utc::now();
    let timestamp = base.to_rfc3339_opts(chrono::SecondsFormat::Secs, true);
    let modified_base = SystemTime::now() - StdDuration::from_secs(3_600);
    for index in 0..32 {
        let path = temp.path().join(format!("session-{index:02}.jsonl"));
        fs::write(
            &path,
            jsonl(&[event(
                "session_meta",
                json!({ "id": format!("session-{index}"), "source": "cli" }),
                &timestamp,
            )]),
        )
        .unwrap();
        fs::OpenOptions::new()
            .write(true)
            .open(path)
            .unwrap()
            .set_modified(modified_base + StdDuration::from_secs(index))
            .unwrap();
    }

    let mut monitor = Monitor::new(temp.path().to_path_buf());
    for _ in 0..12 {
        monitor.poll(base).unwrap();
        assert!(monitor.bytes_read_last_poll() <= Monitor::MAX_POLL_BYTES);
    }

    // Keep the writer open, as Codex does. Holding `now` constant keeps the periodic discovery
    // from noticing the append, so only the watcher's report can get it read.
    let old_path = temp.path().join("session-00.jsonl");
    let start = (base - Duration::seconds(2)).to_rfc3339_opts(chrono::SecondsFormat::Secs, true);
    let completed =
        (base - Duration::seconds(1)).to_rfc3339_opts(chrono::SecondsFormat::Secs, true);
    let mut append = fs::OpenOptions::new().append(true).open(&old_path).unwrap();
    append
        .write_all(&jsonl(&[
            event(
                "event_msg",
                json!({ "type": "task_started", "turn_id": "late-turn", "started_at": start }),
                &start,
            ),
            event(
                "token_usage_record",
                json!({ "turn_id": "late-turn", "turn_token_usage": { "output_tokens": 987 } }),
                &start,
            ),
            event(
                "event_msg",
                json!({ "type": "task_complete", "turn_id": "late-turn", "started_at": start, "completed_at": completed, "duration_ms": 1000 }),
                &completed,
            ),
        ]))
        .unwrap();

    for _ in 0..3 {
        assert!(monitor.poll(base).unwrap().is_empty());
        assert_eq!(
            monitor.bytes_read_last_poll(),
            0,
            "an unreported caught-up file is not opened"
        );
    }

    assert!(monitor.note_changes(&changed(&[&old_path])));
    let records = monitor.poll(base).unwrap();
    assert!(monitor.bytes_read_last_poll() <= Monitor::MAX_POLL_BYTES);
    assert!(
        records.iter().any(|record| record.output_tokens == 987),
        "a reported append must be read by the next poll"
    );
}

#[test]
fn monitor_reads_recent_tail_while_historical_replay_is_bounded_and_resets_on_truncate() {
    let temp = TestDir::new();
    let session = temp.path().join("large-session.jsonl");
    let base = Utc::now();
    let time_text = base.to_rfc3339_opts(chrono::SecondsFormat::Secs, true);
    let mut initial = jsonl(&[event(
        "session_meta",
        json!({ "id": "large", "source": "exec" }),
        &time_text,
    )]);
    for _ in 0..80_000 {
        initial.extend_from_slice(b"{\"type\":\"ignored_event\",\"payload\":{}}\n");
    }
    let mut file = fs::File::create(&session).unwrap();
    file.write_all(&initial).unwrap();

    let mut monitor = Monitor::new(temp.path().to_path_buf());
    for index in 0..4 {
        monitor.poll(base + Duration::seconds(index)).unwrap();
        assert!(monitor.bytes_read_last_poll() <= Monitor::MAX_POLL_BYTES);
    }

    let start = (base - Duration::seconds(2)).to_rfc3339_opts(chrono::SecondsFormat::Secs, true);
    let done = (base - Duration::seconds(1)).to_rfc3339_opts(chrono::SecondsFormat::Secs, true);
    let mut append = fs::OpenOptions::new().append(true).open(&session).unwrap();
    append.write_all(&jsonl(&[
        event("event_msg", json!({ "type": "task_started", "turn_id": "fresh", "started_at": start }), &start),
        event("token_usage_record", json!({ "turn_id": "fresh", "turn_token_usage": { "output_tokens": 120 } }), &start),
        event("event_msg", json!({ "type": "task_complete", "turn_id": "fresh", "started_at": start, "completed_at": done, "duration_ms": 1000 }), &done),
    ])).unwrap();

    let mut fresh = Vec::new();
    for index in 0..12 {
        let records = monitor.poll(base + Duration::seconds(15 + index)).unwrap();
        assert!(monitor.bytes_read_last_poll() <= Monitor::MAX_POLL_BYTES);
        if records.iter().any(|record| record.output_tokens == 120) {
            fresh = records;
            break;
        }
    }
    assert!(
        fresh.iter().any(|record| record.output_tokens == 120),
        "the recent tail must not wait for full replay"
    );

    let short = jsonl(&[
        event(
            "session_meta",
            json!({ "id": "rotated", "source": "cli" }),
            &time_text,
        ),
        event(
            "event_msg",
            json!({ "type": "task_started", "turn_id": "after-truncate", "started_at": start }),
            &start,
        ),
        event(
            "token_usage_record",
            json!({ "turn_id": "after-truncate", "turn_token_usage": { "output_tokens": 77 } }),
            &start,
        ),
        event(
            "event_msg",
            json!({ "type": "task_complete", "turn_id": "after-truncate", "started_at": start, "completed_at": done, "duration_ms": 1000 }),
            &done,
        ),
    ]);
    fs::write(&session, short).unwrap();
    let mut after_truncate = Vec::new();
    for index in 0..10 {
        // No watcher event is reported here; wait for the periodic safety discovery pass.
        after_truncate = monitor
            .poll(base + Duration::seconds(crate::monitor::DISCOVERY_INTERVAL_SECONDS + 1 + index))
            .unwrap();
        assert!(monitor.bytes_read_last_poll() <= Monitor::MAX_POLL_BYTES);
        if after_truncate
            .iter()
            .any(|record| record.output_tokens == 77)
        {
            break;
        }
    }
    assert!(after_truncate
        .iter()
        .any(|record| record.output_tokens == 77));
}

#[test]
fn source_monitor_combines_all_adapters_under_one_poll_budget() {
    let temp = TestDir::new();
    let codex = temp.path().join("codex");
    let claude = temp.path().join("claude-projects");
    let grok = temp.path().join("grok-sessions");
    fs::create_dir_all(&codex).unwrap();
    fs::create_dir_all(&claude).unwrap();
    fs::create_dir_all(&grok).unwrap();

    let start = "2026-10-03T10:00:00Z";
    let end = "2026-10-03T10:00:05Z";
    fs::write(
        codex.join("codex.jsonl"),
        jsonl(&[
            event("session_meta", json!({"id":"codex-synthetic","source":"cli","model_provider":"openai"}), start),
            event("event_msg", json!({"type":"task_started","turn_id":"codex-turn","started_at":start}), start),
            event("token_usage_record", json!({"turn_id":"codex-turn","turn_token_usage":{"output_tokens":50}}), start),
            event("event_msg", json!({"type":"task_complete","turn_id":"codex-turn","started_at":start,"completed_at":end,"duration_ms":5000}), end),
        ]),
    )
    .unwrap();

    let project_dir = claude.join("project-a");
    fs::create_dir_all(&project_dir).unwrap();
    fs::write(
        project_dir.join("transcript.jsonl"),
        jsonl(&[
            claude_user(start, "claude-user", json!("synthetic")),
            claude_message(
                "assistant",
                "assistant",
                end,
                "claude-api-message",
                "claude-sonnet-4",
                "end_turn",
                60,
                json!([]),
            ),
        ]),
    )
    .unwrap();
    let child_dir = project_dir.join("subagents");
    fs::create_dir_all(&child_dir).unwrap();
    fs::write(
        child_dir.join("transcript.jsonl"),
        jsonl(&[
            claude_user(start, "child-user", json!("synthetic")),
            claude_message(
                "assistant",
                "assistant",
                end,
                "child-api-message",
                "claude-sonnet-4",
                "end_turn",
                999,
                json!([]),
            ),
        ]),
    )
    .unwrap();
    fs::write(
        project_dir.join("agent-synthetic.jsonl"),
        jsonl(&[
            claude_user(start, "agent-file-user", json!("synthetic")),
            claude_message(
                "assistant",
                "assistant",
                end,
                "agent-file-call",
                "claude-sonnet-4",
                "end_turn",
                777,
                json!([]),
            ),
        ]),
    )
    .unwrap();

    write_grok_session(
        &grok,
        "grok-session",
        &grok_turn_events("grok-session", 1, "completed"),
        &grok_usage("grok-session", 1, 70),
    );

    let now = time("2026-10-03T10:00:06Z");
    let mut monitor = SourceMonitor::new(
        codex,
        claude,
        grok,
        temp.path().join("gemini"),
        temp.path().join("opencode"),
    );
    let mut found = Vec::new();
    for _ in 0..8 {
        found.extend(monitor.poll(now).unwrap());
        assert!(monitor.bytes_read_last_poll() <= SourceMonitor::MAX_POLL_BYTES);
        if found.iter().any(|row| row.client == GROK_CLIENT)
            && found.iter().any(|row| row.client == CLAUDE_CLIENT)
            && found.iter().any(|row| row.client == "codex")
        {
            break;
        }
    }
    let clients: HashSet<&str> = found.iter().map(|row| row.client.as_str()).collect();
    assert!(clients.contains("codex"));
    assert!(clients.contains(CLAUDE_CLIENT));
    assert!(clients.contains(GROK_CLIENT));
    assert!(!found
        .iter()
        .any(|row| row.output_tokens == 999 || row.output_tokens == 777));
}

#[test]
fn history_deduplicates_prunes_caps_and_persists_only_normalized_metrics() {
    let temp = TestDir::new();
    let path = temp.path().join("history-v1.json");
    let now = time("2026-10-04T10:00:00Z");
    let existing = metric("same-id", now - Duration::hours(2));
    let duplicate = TurnMetric {
        output_tokens: 222,
        ..existing.clone()
    };
    let expired = metric("expired", now - Duration::days(8));
    let future = metric("future", now + Duration::seconds(1));
    let mut legacy = serde_json::to_value(metric("legacy-codex", now)).unwrap();
    let legacy_object = legacy.as_object_mut().unwrap();
    legacy_object.remove("client");
    legacy_object.remove("parserVersion");
    legacy_object.remove("metricVersion");
    fs::write(
        &path,
        serde_json::to_vec(&json!({"schemaVersion":1,"records":[legacy]})).unwrap(),
    )
    .unwrap();
    let restored = History::load(&path, now).unwrap();
    assert_eq!(restored.records()[0].client, "codex");
    assert_eq!(restored.records()[0].parser_version, "codex-rollout-v1");
    assert_eq!(restored.records()[0].metric_version, "turn-v1");
    let mut history = History::default();
    history.merge(&[existing, duplicate, expired, future], now);
    assert_eq!(history.records().len(), 1);
    assert_eq!(history.records()[0].output_tokens, 222);
    history.save(&path).unwrap();
    let saved = fs::read_to_string(&path).unwrap();
    assert!(saved.contains("schemaVersion"));
    assert!(saved.contains("records"));
    assert!(!saved.contains("prompt"));
    assert_eq!(
        History::load(&path, now).unwrap().records(),
        history.records()
    );
    let replacement = TurnMetric {
        output_tokens: 300,
        ..history.records()[0].clone()
    };
    history.merge(&[replacement], now);
    history.save(&path).unwrap();
    assert_eq!(
        History::load(&path, now).unwrap().records()[0].output_tokens,
        300
    );

    let corrupt_path = temp.path().join("corrupt-history.json");
    fs::write(&corrupt_path, b"{not valid json").unwrap();
    let original_corrupt = fs::read(&corrupt_path).unwrap();
    assert!(History::load(&corrupt_path, now).is_err());
    assert_eq!(fs::read(&corrupt_path).unwrap(), original_corrupt);

    let many: Vec<TurnMetric> = (0..History::MAX_RECORDS + 3)
        .map(|index| {
            metric(
                format!("id-{index:05}"),
                now - Duration::seconds(index as i64),
            )
        })
        .collect();
    let mut capped = History::default();
    capped.merge(&many, now);
    assert_eq!(capped.records().len(), History::MAX_RECORDS);
}

#[test]
fn sharing_is_post_enable_only_off_wipes_queue_and_limits_retention() {
    let now = time("2026-10-03T10:00:00Z");
    let mut queue = SharingQueue::new();
    queue.enqueue(&[metric("before-enable", now)], now);
    assert!(queue.is_empty());
    queue.enable(now);
    let old = metric("older", now - Duration::seconds(1));
    let recent = metric("recent", now + Duration::seconds(2));
    queue.enqueue(&[old, recent.clone()], now + Duration::seconds(3));
    assert_eq!(queue.len(), 1);
    let first = queue.batch(now + Duration::minutes(12));
    let retry = queue.batch(now + Duration::minutes(12));
    assert_eq!(first[0].sample_id, retry[0].sample_id);
    assert_eq!(first[0].app_version, "0.1.19");
    queue.disable();
    assert_eq!(queue.len(), 0);
    queue.enqueue(&[recent.clone()], now + Duration::seconds(5));
    assert!(queue.is_empty());
    queue.enable(now + Duration::seconds(5));
    queue.enqueue(&[recent], now + Duration::seconds(6));
    assert_eq!(
        queue.len(),
        0,
        "turns that completed before re-enable must not backfill"
    );

    queue.enable(now + Duration::seconds(10));
    let eligible = metric("eligible", now + Duration::seconds(10));
    queue.enqueue(&[eligible], now + Duration::seconds(11));
    assert_eq!(queue.len(), 1);
    assert!(queue
        .batch(now + Duration::seconds(24 * 60 * 60 + 600))
        .is_empty());

    queue.disable();
    queue.enable(now);
    let many: Vec<TurnMetric> = (0..MAX_PENDING_SAMPLES + 1)
        .map(|index| {
            metric(
                format!("queue-{index}"),
                now + Duration::seconds(index as i64),
            )
        })
        .collect();
    queue.enqueue(&many, now + Duration::seconds(MAX_PENDING_SAMPLES as i64));
    assert_eq!(queue.len(), MAX_PENDING_SAMPLES);
}

#[test]
fn signed_cross_source_json_fixture_uses_exact_wire_fields_and_signature_bytes() {
    let completed = time("2026-10-03T10:03:47Z");
    let mut claude = TurnMetric::new_observed(
        "local-claude-digest".into(),
        completed,
        Some("claude-opus-4-1".into()),
        1200,
        30.0,
        Some("1.2.3".into()),
        None,
        Some("primary".into()),
        Some("anthropic".into()),
        Some("high".into()),
        CLAUDE_CLIENT,
        CLAUDE_PARSER_VERSION,
        CLAUDE_METRIC_VERSION,
    );
    claude.response_output_tokens = Some(900);
    claude.response_duration_seconds = Some(8.0);
    claude.response_count = Some(2);
    claude.delegated_output_tokens = Some(350);
    claude.surface = Some(crate::ToolSurface::Cli);
    // Claude Code: input includes cached tokens (3,000 uncached + 40,000 read + 9,000 written).
    claude.set_prompt_cache(Some(52_000), Some(40_000), Some(9_000));
    let mut bedrock = TurnMetric::new_observed(
        "local-bedrock-digest".into(),
        completed,
        Some("claude-sonnet-4-5-20250929".into()),
        1500,
        20.0,
        Some("1.2.3".into()),
        None,
        Some("primary".into()),
        Some("amazon-bedrock".into()),
        Some("medium".into()),
        CLAUDE_CLIENT,
        CLAUDE_PARSER_VERSION,
        CLAUDE_METRIC_VERSION,
    );
    bedrock.response_output_tokens = Some(1200);
    bedrock.response_duration_seconds = Some(9.0);
    bedrock.response_count = Some(3);
    bedrock.provider_region = Some("eu".into());
    bedrock.delegated_output_tokens = Some(0);
    bedrock.surface = Some(crate::ToolSurface::Desktop);
    // A first request: nothing read from the cache, 12,000 tokens written to it.
    bedrock.set_prompt_cache(Some(18_000), Some(0), Some(12_000));
    let subagent = TurnMetric::new_observed(
        "local-subagent-digest".into(),
        completed,
        Some("claude-sonnet-5-5".into()),
        90,
        3.0,
        Some("1.2.3".into()),
        None,
        Some("subagent".into()),
        Some("unknown".into()),
        None,
        CLAUDE_CLIENT,
        CLAUDE_PARSER_VERSION,
        CLAUDE_SUBAGENT_METRIC_VERSION,
    );
    let mut grok = TurnMetric::new_observed(
        "local-grok-digest".into(),
        completed,
        Some("grok-4".into()),
        1200,
        12.0,
        None,
        Some(70),
        Some("primary".into()),
        Some("unknown".into()),
        None,
        GROK_CLIENT,
        GROK_PARSER_VERSION,
        GROK_METRIC_VERSION,
    );
    grok.response_output_tokens = Some(1200);
    grok.response_duration_seconds = Some(10.0);
    grok.response_count = Some(4);
    grok.delegated_output_tokens = Some(0);
    // Grok Build reports no cache write.
    grok.set_prompt_cache(Some(90_000), Some(70_000), None);
    let samples = [
        crate::SharedSample::from_metric(
            &claude,
            Uuid::parse_str("00000000-0000-4000-8000-000000000001").unwrap(),
        )
        .unwrap(),
        crate::SharedSample::from_metric(
            &grok,
            Uuid::parse_str("00000000-0000-4000-8000-000000000002").unwrap(),
        )
        .unwrap(),
        crate::SharedSample::from_metric(
            &subagent,
            Uuid::parse_str("00000000-0000-4000-8000-000000000003").unwrap(),
        )
        .unwrap(),
        crate::SharedSample::from_metric(
            &bedrock,
            Uuid::parse_str("00000000-0000-4000-8000-000000000004").unwrap(),
        )
        .unwrap(),
    ];
    let now = time("2026-10-03T10:05:00Z");
    let key = [7_u8; 32];
    let request = signed_request(&samples, &key, now).unwrap();
    if std::env::var_os("TOKRATE_EXPORT_SIGNED_FIXTURE").is_some() {
        let packet = json!({
            "provenance":"Generated by the Rust core deterministic synthetic test; no local logs or credentials",
            "rawBody":String::from_utf8(request.body.clone()).unwrap(),
            "publicKey":request.public_key,
            "signature":request.signature
        });
        fs::write(
            Path::new(env!("CARGO_MANIFEST_DIR"))
                .join("tests/fixtures/rust-signed-request-v0.1.19-mixed.json"),
            serde_json::to_vec_pretty(&packet).unwrap(),
        )
        .unwrap();
        return;
    }
    let actual: Value = serde_json::from_slice(&request.body).unwrap();
    let packet: Value = serde_json::from_str(include_str!(
        "../tests/fixtures/rust-signed-request-v0.1.19-mixed.json"
    ))
    .unwrap();
    assert_eq!(
        String::from_utf8(request.body.clone()).unwrap(),
        packet["rawBody"]
    );
    assert_eq!(request.public_key, packet["publicKey"]);
    assert_eq!(request.signature, packet["signature"]);
    assert_eq!(actual["samples"].as_array().unwrap().len(), 4);
    assert_eq!(actual["samples"][0]["client"], "claude-code");
    assert_eq!(actual["samples"][0]["provider"], "anthropic");
    assert_eq!(actual["samples"][0]["ttftMs"], Value::Null);
    assert_eq!(actual["samples"][1]["client"], "grok-build");
    assert_eq!(actual["samples"][1]["clientVersion"], "unknown");
    assert_eq!(actual["samples"][1]["ttftMs"], Value::Null);
    assert_eq!(actual["samples"][2]["client"], "claude-code");
    assert_eq!(actual["samples"][2]["sourceKind"], "subagent");
    assert_eq!(
        actual["samples"][2]["metricVersion"],
        "claude-observed-subagent-turn-v1"
    );
    assert_eq!(actual["samples"][2]["appVersion"], "0.1.19");
    assert_eq!(actual["samples"][3]["client"], "claude-code");
    assert_eq!(actual["samples"][3]["provider"], "amazon-bedrock");
    assert_eq!(actual["samples"][3]["model"], "claude-sonnet-4-5-20250929");
    // Response fields and the Bedrock region are always present; null when absent.
    assert_eq!(actual["samples"][0]["responseOutputTokens"], 900);
    assert_eq!(actual["samples"][0]["responseDurationMs"], 8000.0);
    assert_eq!(actual["samples"][0]["responseCount"], 2);
    assert_eq!(actual["samples"][0]["providerRegion"], Value::Null);
    // Grok Build reports a whole-turn average over its model calls under parser v2.
    assert_eq!(actual["samples"][1]["parserVersion"], "grok-session-v2");
    assert_eq!(actual["samples"][1]["responseOutputTokens"], 1200);
    assert_eq!(actual["samples"][1]["responseDurationMs"], 10000.0);
    assert_eq!(actual["samples"][1]["responseCount"], 4);
    assert_eq!(actual["samples"][2]["responseCount"], Value::Null);
    assert_eq!(actual["samples"][3]["responseDurationMs"], 9000.0);
    assert_eq!(actual["samples"][3]["providerRegion"], "eu");
    // Delegated output is always present: a number for primary turns, null for subagents.
    assert_eq!(actual["samples"][0]["delegatedOutputTokens"], 350);
    assert_eq!(actual["samples"][1]["delegatedOutputTokens"], 0);
    assert_eq!(actual["samples"][2]["delegatedOutputTokens"], Value::Null);
    assert_eq!(actual["samples"][3]["delegatedOutputTokens"], 0);
    // The surface category is always present: a name when known, null otherwise (Grok, subagent).
    assert_eq!(actual["samples"][0]["surface"], "cli");
    assert_eq!(actual["samples"][1]["surface"], Value::Null);
    assert_eq!(actual["samples"][2]["surface"], Value::Null);
    assert_eq!(actual["samples"][3]["surface"], "desktop");
    // Prompt-cache fields are always present: numbers when reported, null otherwise (the write is
    // Claude Code only, a subagent here reports none).
    assert_eq!(actual["samples"][0]["inputTokens"], 52_000);
    assert_eq!(actual["samples"][0]["cacheReadInputTokens"], 40_000);
    assert_eq!(actual["samples"][0]["cacheWriteInputTokens"], 9_000);
    assert_eq!(actual["samples"][1]["inputTokens"], 90_000);
    assert_eq!(actual["samples"][1]["cacheReadInputTokens"], 70_000);
    assert_eq!(actual["samples"][1]["cacheWriteInputTokens"], Value::Null);
    for key in [
        "inputTokens",
        "cacheReadInputTokens",
        "cacheWriteInputTokens",
    ] {
        assert_eq!(actual["samples"][2][key], Value::Null, "{key}");
    }
    assert_eq!(actual["samples"][3]["inputTokens"], 18_000);
    assert_eq!(actual["samples"][3]["cacheReadInputTokens"], 0);
    assert_eq!(actual["samples"][3]["cacheWriteInputTokens"], 12_000);
    assert!(!request
        .body
        .windows(b"local-claude-digest".len())
        .any(|window| window == b"local-claude-digest"));

    use base64::engine::general_purpose::STANDARD as BASE64;
    use base64::Engine;
    let public_bytes: [u8; 32] = BASE64
        .decode(&request.public_key)
        .unwrap()
        .try_into()
        .unwrap();
    let signature_bytes: [u8; 64] = BASE64
        .decode(&request.signature)
        .unwrap()
        .try_into()
        .unwrap();
    let verifying_key = VerifyingKey::from_bytes(&public_bytes).unwrap();
    verifying_key
        .verify(&request.body, &Signature::from_bytes(&signature_bytes))
        .unwrap();
    let changed = [request.body.as_slice(), b" "].concat();
    assert!(verifying_key
        .verify(&changed, &Signature::from_bytes(&signature_bytes))
        .is_err());
}

#[test]
fn samples_fail_closed_on_invalid_numbers_and_explicitly_null_missing_fields() {
    let now = time("2026-10-03T10:00:00Z");
    let mut invalid = metric("invalid", now);
    invalid.duration_seconds = f64::NAN;
    assert!(crate::SharedSample::from_metric(&invalid, Uuid::new_v4()).is_none());

    let mut missing = metric("missing", now);
    missing.model = None;
    missing.provider = Some("other-provider".into());
    missing.reasoning_effort = Some("automatic".into());
    missing.reasoning_output_tokens = Some(300);
    missing.codex_ttft_seconds = Some(30.0);
    let sample = crate::SharedSample::from_metric(&missing, Uuid::new_v4()).unwrap();
    assert_eq!(sample.model, "unknown");
    assert_eq!(sample.provider, "unknown");
    assert_eq!(sample.reasoning_effort, "unknown");
    assert_eq!(sample.reasoning_output_tokens, None);
    assert_eq!(sample.ttft_ms, None);
    let json = serde_json::to_value(sample).unwrap();
    assert!(json.get("reasoningOutputTokens").unwrap().is_null());
    assert!(json.get("ttftMs").unwrap().is_null());
}

const ANTHROPIC_MESSAGE: &str = "msg_01ABCDEFGHJKLMNPQRSTUVwx";
const ANTHROPIC_MESSAGE_2: &str = "msg_01ZYXWVUTSRQPNMLKJHGFEdc";
const ANTHROPIC_REQUEST: &str = "req_011CPabcdefghijklmnopqrstuv";
const BEDROCK_MESSAGE: &str = "msg_bdrk_01ABCDEFGHJKLMNPQRSTUVwx";
const VERTEX_MESSAGE: &str = "msg_vrtx_01ABCDEFGHJKLMNPQRSTUVwx";

fn with_request(line: Vec<u8>) -> Vec<u8> {
    with_fields(line, json!({ "requestId": ANTHROPIC_REQUEST }))
}

/// Runs one primary turn of two assistant messages and returns the emitted provider.
fn provider_of_turn(first: Vec<u8>, second: Vec<u8>) -> Option<String> {
    let mut parser = claude_parser();
    parser.consume(&claude_user(
        "2026-10-03T10:00:00Z",
        "provider-turn",
        json!("synthetic"),
    ));
    parser.consume(&first);
    parser.consume_settled(&second)?.provider
}

#[test]
fn claude_provider_comes_only_from_explicit_message_and_request_identifiers() {
    let direct = |at: &str, id: &str, stop: &str| with_request(assistant(at, id, stop, 5));
    let bedrock = |at: &str, id: &str, stop: &str| assistant(at, id, stop, 5);

    assert_eq!(
        provider_of_turn(
            direct("2026-10-03T10:00:05Z", ANTHROPIC_MESSAGE, "tool_use"),
            direct("2026-10-03T10:00:10Z", ANTHROPIC_MESSAGE_2, "end_turn"),
        )
        .as_deref(),
        Some("anthropic")
    );
    assert_eq!(
        provider_of_turn(
            bedrock("2026-10-03T10:00:05Z", BEDROCK_MESSAGE, "tool_use"),
            bedrock(
                "2026-10-03T10:00:10Z",
                "msg_bdrk_01ZYXWVUTSRQPNMLKJHGFEdc",
                "end_turn"
            ),
        )
        .as_deref(),
        Some("amazon-bedrock")
    );
    assert_eq!(
        provider_of_turn(
            bedrock("2026-10-03T10:00:05Z", VERTEX_MESSAGE, "tool_use"),
            bedrock(
                "2026-10-03T10:00:10Z",
                "msg_vrtx_01ZYXWVUTSRQPNMLKJHGFEdc",
                "end_turn"
            ),
        )
        .as_deref(),
        Some("google-vertex")
    );
    // A first-party-shaped id without its request id is not evidence (proxies copy the shape).
    assert_eq!(
        provider_of_turn(
            assistant("2026-10-03T10:00:05Z", ANTHROPIC_MESSAGE, "tool_use", 5),
            assistant("2026-10-03T10:00:10Z", ANTHROPIC_MESSAGE_2, "end_turn", 5),
        )
        .as_deref(),
        Some("unknown")
    );
    // One message without evidence makes the whole turn unknown, in either position.
    assert_eq!(
        provider_of_turn(
            direct("2026-10-03T10:00:05Z", ANTHROPIC_MESSAGE, "tool_use"),
            assistant("2026-10-03T10:00:10Z", ANTHROPIC_MESSAGE_2, "end_turn", 5),
        )
        .as_deref(),
        Some("unknown")
    );
    assert_eq!(
        provider_of_turn(
            assistant("2026-10-03T10:00:05Z", "plain-call-1", "tool_use", 5),
            direct("2026-10-03T10:00:10Z", ANTHROPIC_MESSAGE, "end_turn"),
        )
        .as_deref(),
        Some("unknown")
    );
    // Different providers within one turn never pick a winner.
    assert_eq!(
        provider_of_turn(
            direct("2026-10-03T10:00:05Z", ANTHROPIC_MESSAGE, "tool_use"),
            bedrock("2026-10-03T10:00:10Z", BEDROCK_MESSAGE, "end_turn"),
        )
        .as_deref(),
        Some("unknown")
    );
}

#[test]
fn claude_provider_rejects_malformed_identifiers() {
    use crate::claude_parser::provider_evidence;
    let request = Some(ANTHROPIC_REQUEST);
    assert_eq!(
        provider_evidence(ANTHROPIC_MESSAGE, request),
        Some("anthropic")
    );
    // Wrong lengths and characters.
    assert_eq!(
        provider_evidence("msg_01ABCDEFGHJKLMNPQRSTUV", request),
        None
    );
    assert_eq!(
        provider_evidence("msg_01ABCDEFGHJKLMNPQRSTUVwxy", request),
        None
    );
    assert_eq!(
        provider_evidence("msg_01ABCDEFGHJKLMNPQRSTU-wx", request),
        None
    );
    assert_eq!(
        provider_evidence("msg_02ABCDEFGHJKLMNPQRSTUVwx", request),
        None
    );
    assert_eq!(
        provider_evidence(ANTHROPIC_MESSAGE, Some("req_short")),
        None
    );
    assert_eq!(
        provider_evidence(ANTHROPIC_MESSAGE, Some("req_011CPabcdefghijklmnopqrstuv_")),
        None
    );
    assert_eq!(
        provider_evidence(ANTHROPIC_MESSAGE, Some("011CPabcdefghijklmnopqrstuv")),
        None
    );
    assert_eq!(provider_evidence(ANTHROPIC_MESSAGE, None), None);
    // Bedrock and Vertex need 8..=64 alphanumerics and no request id.
    assert_eq!(
        provider_evidence("msg_bdrk_12345678", None),
        Some("amazon-bedrock")
    );
    assert_eq!(provider_evidence("msg_bdrk_1234567", None), None);
    assert_eq!(
        provider_evidence(&format!("msg_bdrk_{}", "a".repeat(64)), None),
        Some("amazon-bedrock")
    );
    assert_eq!(
        provider_evidence(&format!("msg_bdrk_{}", "a".repeat(65)), None),
        None
    );
    assert_eq!(provider_evidence("msg_bdrk_1234567_", None), None);
    assert_eq!(
        provider_evidence("msg_vrtx_12345678", None),
        Some("google-vertex")
    );
    assert_eq!(provider_evidence("msg_vrtx_1234567", None), None);
    assert_eq!(provider_evidence("msg_xxxx_12345678", None), None);
}

#[test]
fn claude_subagent_provider_uses_the_same_evidence() {
    let session = "sub-session";
    let agent = "sub-agent";
    let user = |id: &str, at: &str| as_subagent(claude_user(at, id, json!("task")), session, agent);
    let reply = |at: &str, id: &str, stop: &str, request: bool| {
        let line = as_subagent(assistant(at, id, stop, 20), session, agent);
        if request {
            with_request(line)
        } else {
            line
        }
    };
    let mut direct = crate::claude_parser::ClaudeTranscriptParser::new_subagent("file".into());
    direct.consume_settled(&user("task-1", "2026-10-03T10:00:00Z"));
    direct.consume_settled(&reply(
        "2026-10-03T10:00:04Z",
        ANTHROPIC_MESSAGE,
        "tool_use",
        true,
    ));
    let found = direct
        .consume_settled(&reply(
            "2026-10-03T10:00:10Z",
            ANTHROPIC_MESSAGE_2,
            "end_turn",
            true,
        ))
        .unwrap();
    assert_eq!(found.provider.as_deref(), Some("anthropic"));
    assert_eq!(found.source_kind.as_deref(), Some("subagent"));

    let mut bedrock = crate::claude_parser::ClaudeTranscriptParser::new_subagent("file".into());
    bedrock.consume_settled(&user("task-1", "2026-10-03T10:00:00Z"));
    let found = bedrock
        .consume_settled(&reply(
            "2026-10-03T10:00:10Z",
            BEDROCK_MESSAGE,
            "end_turn",
            false,
        ))
        .unwrap();
    assert_eq!(found.provider.as_deref(), Some("amazon-bedrock"));

    let mut missing = crate::claude_parser::ClaudeTranscriptParser::new_subagent("file".into());
    missing.consume_settled(&user("task-1", "2026-10-03T10:00:00Z"));
    let found = missing
        .consume_settled(&reply(
            "2026-10-03T10:00:10Z",
            ANTHROPIC_MESSAGE,
            "end_turn",
            false,
        ))
        .unwrap();
    assert_eq!(found.provider.as_deref(), Some("unknown"));
}

#[test]
fn claude_model_names_are_normalized_before_the_safe_identifier_check() {
    use crate::claude_parser::normalize_claude_model as normalize;
    let cases: &[(&str, Option<&str>)] = &[
        // Plain first-party names are unchanged, including dots.
        ("claude-sonnet-4-5-20250929", Some("claude-sonnet-4-5-20250929")),
        ("claude-opus-4.5", Some("claude-opus-4.5")),
        ("gpt-test", Some("gpt-test")),
        // Bedrock: region prefixes and version suffixes are optional.
        (
            "us.anthropic.claude-sonnet-4-5-20250929-v1:0",
            Some("claude-sonnet-4-5-20250929"),
        ),
        (
            "anthropic.claude-3-haiku-20240307-v1:0",
            Some("claude-3-haiku-20240307"),
        ),
        ("global.anthropic.claude-opus-4-6-v1", Some("claude-opus-4-6")),
        ("us-gov.anthropic.claude-sonnet-4-5-v2", Some("claude-sonnet-4-5")),
        ("eu.anthropic.claude-sonnet-4-5", Some("claude-sonnet-4-5")),
        ("anthropic.claude-v1", Some("claude-v1")),
        // Vertex.
        (
            "claude-sonnet-4-5@20250929",
            Some("claude-sonnet-4-5-20250929"),
        ),
        ("claude-3-haiku@20240307", Some("claude-3-haiku-20240307")),
        // Rejected: ARNs, malformed versions and anything else unsafe.
        (
            "arn:aws:bedrock:us-east-1:123456789012:inference-profile/us.anthropic.claude-sonnet-4-5-v1:0",
            None,
        ),
        ("claude-sonnet-4-5@latest", None),
        ("claude-sonnet-4-5@2025092", None),
        ("claude-sonnet-4-5@202509299", None),
        ("claude-sonnet-4-5@20250929@20250929", None),
        ("claude-sonnet-4-5:0", None),
        ("anthropic.claude-sonnet-4-5-v1:", None),
        ("anthropic.claude-sonnet-4-5:0", None),
        ("anthropic.gpt-4-v1:0", None),
        ("Anthropic.claude-sonnet-4-5-v1:0", None),
        ("us.anthropic.Claude-sonnet-4-5-v1:0", None),
        ("toolong.anthropic.claude-sonnet-4-5-v1:0", None),
        ("a.anthropic.claude-sonnet-4-5-v1:0", None),
        ("", None),
        ("claude sonnet", None),
    ];
    for (raw, expected) in cases {
        assert_eq!(normalize(raw).as_deref(), *expected, "{raw}");
    }
    // The normalized value still obeys the 80-byte public limit.
    let long = format!("anthropic.claude-{}-v1:0", "a".repeat(80));
    assert_eq!(normalize(&long), None);
}

#[test]
fn claude_model_consistency_compares_normalized_names_across_routes() {
    let model_line = |at: &str, id: &str, stop: &str, model: &str| {
        claude_message("assistant", "assistant", at, id, model, stop, 5, json!([]))
    };
    let mut same = claude_parser();
    same.consume_settled(&claude_user("2026-10-03T10:00:00Z", "turn", json!("x")));
    same.consume_settled(&model_line(
        "2026-10-03T10:00:05Z",
        "call-1",
        "tool_use",
        "us.anthropic.claude-sonnet-4-5-20250929-v1:0",
    ));
    let found = same
        .consume_settled(&model_line(
            "2026-10-03T10:00:10Z",
            "call-2",
            "end_turn",
            "claude-sonnet-4-5@20250929",
        ))
        .unwrap();
    assert_eq!(found.model.as_deref(), Some("claude-sonnet-4-5-20250929"));

    let mut different = claude_parser();
    different.consume_settled(&claude_user("2026-10-03T10:00:00Z", "turn", json!("x")));
    different.consume_settled(&model_line(
        "2026-10-03T10:00:05Z",
        "call-1",
        "tool_use",
        "anthropic.claude-sonnet-4-5-20250929-v1:0",
    ));
    let found = different
        .consume_settled(&model_line(
            "2026-10-03T10:00:10Z",
            "call-2",
            "end_turn",
            "claude-opus-4-6",
        ))
        .unwrap();
    assert_eq!(found.model, None);

    // An ARN cannot be normalized, so the turn has no model rather than a raw value.
    let mut arn = claude_parser();
    arn.consume_settled(&claude_user("2026-10-03T10:00:00Z", "turn", json!("x")));
    let found = arn
        .consume_settled(&model_line(
            "2026-10-03T10:00:10Z",
            "call-1",
            "end_turn",
            "arn:aws:bedrock:us-east-1:123456789012:inference-profile/x",
        ))
        .unwrap();
    assert_eq!(found.model, None);
}

#[test]
fn sharing_allowlists_bedrock_and_vertex_providers_only_for_claude_code() {
    let completed = time("2026-10-03T10:03:47Z");
    let build = |client: &str, parser: &str, metric_version: &str, provider: &str| {
        let mut turn = TurnMetric::new_observed(
            "local-digest".into(),
            completed,
            Some("claude-sonnet-4-5-20250929".into()),
            90,
            3.0,
            Some("2.1.0".into()),
            None,
            Some("primary".into()),
            Some(provider.into()),
            Some("high".into()),
            client,
            parser,
            metric_version,
        );
        turn.delegated_output_tokens = Some(0);
        turn
    };
    let shared = |metric: &TurnMetric| {
        crate::SharedSample::from_metric(metric, Uuid::new_v4())
            .unwrap()
            .provider
    };
    for provider in ["anthropic", "amazon-bedrock", "google-vertex", "unknown"] {
        assert_eq!(
            shared(&build(
                CLAUDE_CLIENT,
                CLAUDE_PARSER_VERSION,
                CLAUDE_METRIC_VERSION,
                provider
            )),
            provider
        );
        assert_eq!(
            shared(&build(
                CLAUDE_CLIENT,
                CLAUDE_PARSER_VERSION,
                CLAUDE_SUBAGENT_METRIC_VERSION,
                provider
            )),
            provider
        );
    }
    for provider in ["amazon-bedrock", "google-vertex"] {
        assert_eq!(
            shared(&build(
                GROK_CLIENT,
                GROK_PARSER_VERSION,
                GROK_METRIC_VERSION,
                provider
            )),
            "unknown"
        );
        assert_eq!(
            shared(&build(
                crate::CODEX_CLIENT,
                crate::CODEX_PARSER_VERSION,
                crate::CODEX_METRIC_VERSION,
                provider
            )),
            "unknown"
        );
    }
    assert_eq!(
        shared(&build(
            GROK_CLIENT,
            GROK_PARSER_VERSION,
            GROK_METRIC_VERSION,
            "xai"
        )),
        "xai"
    );
    assert_eq!(
        shared(&build(
            crate::CODEX_CLIENT,
            crate::CODEX_PARSER_VERSION,
            crate::CODEX_METRIC_VERSION,
            "openai"
        )),
        "openai"
    );
    assert_eq!(
        shared(&build(
            CLAUDE_CLIENT,
            CLAUDE_PARSER_VERSION,
            CLAUDE_METRIC_VERSION,
            "other-provider"
        )),
        "unknown"
    );
    assert_eq!(crate::APP_VERSION, "0.1.19");

    // Parser v1 and v2 records (saved by earlier versions) are never shared.
    for old_parser in [
        "claude-transcript-v1",
        "claude-transcript-v2",
        "claude-transcript-v3",
    ] {
        let legacy = build(
            CLAUDE_CLIENT,
            old_parser,
            CLAUDE_METRIC_VERSION,
            "anthropic",
        );
        assert!(crate::SharedSample::from_metric(&legacy, Uuid::new_v4()).is_none());
    }
    assert_eq!(CLAUDE_PARSER_VERSION, "claude-transcript-v4");
}

fn user_with(at: &str, id: &str, fields: Value) -> Vec<u8> {
    with_fields(claude_user(at, id, json!("synthetic")), fields)
}

fn assistant_end(at: &str, id: &str) -> Vec<u8> {
    assistant(at, id, "end_turn", 40)
}

#[test]
fn claude_task_notifications_are_activity_never_prompts() {
    let notification = |at: &str, id: &str| {
        user_with(at, id, json!({ "origin": { "kind": "task-notification" } }))
    };
    // After a terminal record a notification starts nothing, so later assistant records
    // (the model reacting to it) emit no measurement.
    let mut after = claude_parser();
    after.consume_settled(&claude_user("2026-10-03T10:00:00Z", "human", json!("go")));
    assert!(after
        .consume_settled(&assistant_end("2026-10-03T10:00:10Z", "call-1"))
        .is_some());
    assert!(after
        .consume_settled(&notification("2026-10-03T10:05:00Z", "note-1"))
        .is_none());
    assert!(after
        .consume_settled(&assistant("2026-10-03T10:05:05Z", "call-2", "tool_use", 9))
        .is_none());
    assert!(after
        .consume_settled(&assistant_end("2026-10-03T10:05:10Z", "call-3"))
        .is_none());

    // Mid-turn it neither restarts the turn nor continues it as an interjection: only activity.
    let mut mid = claude_parser();
    mid.consume_settled(&claude_user("2026-10-03T10:00:00Z", "human", json!("go")));
    mid.consume_settled(&assistant("2026-10-03T10:00:10Z", "call-1", "tool_use", 5));
    mid.consume_settled(&notification("2026-10-03T10:00:20Z", "note-1"));
    let found = mid
        .consume_settled(&assistant_end("2026-10-03T10:00:40Z", "call-2"))
        .unwrap();
    assert_eq!(found.duration_seconds, 40.0);
    assert_eq!(found.output_tokens, 45);

    // A background event never discards the active turn the way a real interruption does.
    let mut keeps = claude_parser();
    keeps.consume_settled(&claude_user("2026-10-03T10:00:00Z", "human", json!("go")));
    keeps.consume_settled(&notification("2026-10-03T10:00:05Z", "note-1"));
    assert!(keeps
        .consume_settled(&assistant_end("2026-10-03T10:00:10Z", "call-1"))
        .is_some());

    // Human origin and origin-less records follow the v2 rules.
    let mut human = claude_parser();
    human.consume_settled(&user_with(
        "2026-10-03T10:00:00Z",
        "human",
        json!({ "origin": { "kind": "human" } }),
    ));
    assert!(human
        .consume_settled(&assistant_end("2026-10-03T10:00:10Z", "call-1"))
        .is_some());
}

#[test]
fn claude_subagent_coordinator_follow_ups_are_prompts_even_when_meta() {
    let session = "11111111-2222-4333-8444-555555555555";
    let agent = "a1b2c3d4e5f60718";
    let record = |line: Vec<u8>| as_subagent(line, session, agent);
    let mut parser = crate::claude_parser::ClaudeTranscriptParser::new_subagent("file".into());
    parser.consume_settled(&record(claude_user(
        "2026-10-03T10:00:00Z",
        "task-1",
        json!("task"),
    )));
    let first = parser
        .consume_settled(&record(assistant_end("2026-10-03T10:00:10Z", "sub-1")))
        .unwrap();
    parser.consume_settled(&record(user_with(
        "2026-10-03T10:10:00Z",
        "follow-up",
        json!({ "isMeta": true, "origin": { "kind": "coordinator" } }),
    )));
    let second = parser
        .consume_settled(&record(assistant_end("2026-10-03T10:10:20Z", "sub-2")))
        .unwrap();
    assert_ne!(first.id, second.id);
    assert_eq!(second.duration_seconds, 20.0);

    // Other meta records, with or without an origin, stay ignored.
    let mut ignored = crate::claude_parser::ClaudeTranscriptParser::new_subagent("file".into());
    ignored.consume_settled(&record(user_with(
        "2026-10-03T10:00:00Z",
        "meta",
        json!({ "isMeta": true, "origin": { "kind": "task-notification" } }),
    )));
    ignored.consume_settled(&record(user_with(
        "2026-10-03T10:00:01Z",
        "meta-2",
        json!({ "isMeta": true }),
    )));
    assert!(ignored
        .consume_settled(&record(assistant_end("2026-10-03T10:00:10Z", "sub-1")))
        .is_none());

    // A non-meta record with a background origin is activity only in a subagent file: it
    // neither starts a turn after a terminal record nor continues or discards an active one.
    let mut background = crate::claude_parser::ClaudeTranscriptParser::new_subagent("file".into());
    background.consume_settled(&record(claude_user(
        "2026-10-03T10:00:00Z",
        "task-1",
        json!("task"),
    )));
    assert!(background
        .consume_settled(&record(assistant_end("2026-10-03T10:00:10Z", "sub-1")))
        .is_some());
    background.consume_settled(&record(user_with(
        "2026-10-03T10:05:00Z",
        "note-1",
        json!({ "origin": { "kind": "task-notification" } }),
    )));
    assert!(background
        .consume_settled(&record(assistant_end("2026-10-03T10:05:10Z", "sub-2")))
        .is_none());
    let mut mid = crate::claude_parser::ClaudeTranscriptParser::new_subagent("file".into());
    mid.consume_settled(&record(claude_user(
        "2026-10-03T10:00:00Z",
        "task-1",
        json!("task"),
    )));
    mid.consume_settled(&record(assistant(
        "2026-10-03T10:00:10Z",
        "sub-1",
        "tool_use",
        5,
    )));
    mid.consume_settled(&record(user_with(
        "2026-10-03T10:00:20Z",
        "note-1",
        json!({ "origin": { "kind": "task-notification" } }),
    )));
    let found = mid
        .consume_settled(&record(assistant_end("2026-10-03T10:00:30Z", "sub-2")))
        .unwrap();
    assert_eq!(found.duration_seconds, 30.0);
    // Human origin is an ordinary prompt in a subagent file.
    let mut human = crate::claude_parser::ClaudeTranscriptParser::new_subagent("file".into());
    human.consume_settled(&record(user_with(
        "2026-10-03T10:00:00Z",
        "task-1",
        json!({ "origin": { "kind": "human" } }),
    )));
    assert!(human
        .consume_settled(&record(assistant_end("2026-10-03T10:00:10Z", "sub-1")))
        .is_some());

    // A follow-up within 30 minutes of active work continues the same turn (v2 rules).
    let mut continued = crate::claude_parser::ClaudeTranscriptParser::new_subagent("file".into());
    continued.consume_settled(&record(claude_user(
        "2026-10-03T10:00:00Z",
        "task-1",
        json!("task"),
    )));
    continued.consume_settled(&record(assistant(
        "2026-10-03T10:00:10Z",
        "sub-1",
        "tool_use",
        5,
    )));
    continued.consume_settled(&record(user_with(
        "2026-10-03T10:00:20Z",
        "follow-up",
        json!({ "isMeta": true, "origin": { "kind": "coordinator" } }),
    )));
    let found = continued
        .consume_settled(&record(assistant_end("2026-10-03T10:00:30Z", "sub-2")))
        .unwrap();
    assert_eq!(found.duration_seconds, 30.0);
}

#[test]
fn claude_parser_started_mid_file_waits_for_a_turn_boundary() {
    // Terminal assistant boundary: the partial turn is skipped, the next full turn is measured.
    let mut tail = claude_parser();
    tail.begin_mid_file();
    tail.consume_settled(&claude_user("2026-10-03T10:00:00Z", "partial", json!("go")));
    assert!(tail
        .consume_settled(&assistant_end("2026-10-03T10:00:10Z", "partial-end"))
        .is_none());
    tail.consume_settled(&claude_user("2026-10-03T10:01:00Z", "full", json!("go")));
    let found = tail
        .consume_settled(&assistant_end("2026-10-03T10:01:10Z", "full-end"))
        .unwrap();
    assert_eq!(found.duration_seconds, 10.0);

    // A prompt without a null parentUuid cannot synchronise, even after a notification.
    let mut unsynced = claude_parser();
    unsynced.begin_mid_file();
    unsynced.consume_settled(&user_with(
        "2026-10-03T10:00:00Z",
        "mid",
        json!({ "parentUuid": "previous-record" }),
    ));
    assert!(unsynced
        .consume_settled(&assistant_end("2026-10-03T10:00:10Z", "mid-end"))
        .is_none());

    // A conversation's first prompt (parentUuid null) is a boundary and starts a turn.
    let mut first = claude_parser();
    first.begin_mid_file();
    first.consume_settled(&user_with(
        "2026-10-03T10:00:00Z",
        "first",
        json!({ "parentUuid": null }),
    ));
    assert!(first
        .consume_settled(&assistant_end("2026-10-03T10:00:10Z", "first-end"))
        .is_some());

    // A parser reading from the start never waits.
    let mut archive = claude_parser();
    archive.consume_settled(&claude_user("2026-10-03T10:00:00Z", "full", json!("go")));
    assert!(archive
        .consume_settled(&assistant_end("2026-10-03T10:00:10Z", "full-end"))
        .is_some());
}

#[test]
fn recent_tail_reader_synchronizes_claude_transcripts_but_archive_reads_everything() {
    let temp = TestDir::new();
    let path = temp.path().join("transcript.jsonl");
    let mut contents = jsonl(&[user_with(
        "2026-10-03T09:00:00Z",
        "header",
        json!({ "parentUuid": null }),
    )]);
    contents.extend_from_slice(&jsonl(&[assistant(
        "2026-10-03T09:00:05Z",
        "head-1",
        "tool_use",
        3,
    )]));
    for _ in 0..4_000 {
        contents.extend_from_slice(b"{\"type\":\"ignored_event\",\"padding\":\"0123456789012345678901234567890123456789012345678901234567890123456789\"}\n");
    }
    contents.extend_from_slice(&jsonl(&[
        claude_user("2026-10-03T10:00:00Z", "partial", json!("go")),
        assistant_end("2026-10-03T10:00:10Z", "partial-end"),
        claude_user("2026-10-03T10:01:00Z", "full", json!("go")),
        assistant_end("2026-10-03T10:01:10Z", "full-end"),
    ]));
    fs::write(&path, &contents).unwrap();

    let poll_all = |mut reader: crate::reader::IncrementalReader| {
        let mut found = Vec::new();
        for _ in 0..8 {
            found.extend(
                reader
                    .poll(8 * 1_048_576, time("2026-10-03T11:00:00Z"))
                    .unwrap(),
            );
        }
        found
    };
    let tail = poll_all(crate::reader::IncrementalReader::recent_tail_claude(
        path.clone(),
    ));
    assert_eq!(
        tail.len(),
        1,
        "partial turn skipped, next full turn measured"
    );
    assert_eq!(tail[0].duration_seconds, 10.0);

    let archive = poll_all(crate::reader::IncrementalReader::beginning_claude(path));
    assert_eq!(
        archive.len(),
        2,
        "reading from the start keeps every complete turn"
    );
}

#[test]
fn codex_parser_requires_the_observed_turn_start() {
    let start = "2026-10-03T10:00:00Z";
    let end = "2026-10-03T10:00:05Z";
    let feed = |parser: &mut crate::parser::CodexEventParser, with_start: bool| {
        parser.consume(&event(
            "session_meta",
            json!({ "id": "codex-session", "source": "cli", "model_provider": "openai" }),
            start,
        ));
        if with_start {
            parser.consume(&event(
                "event_msg",
                json!({ "type": "task_started", "turn_id": "turn", "started_at": start }),
                start,
            ));
        }
        parser.consume(&event(
            "turn_context",
            json!({ "turn_id": "turn", "model": "gpt-test", "effort": "high" }),
            start,
        ));
        parser.consume(&event(
            "token_usage_record",
            json!({ "turn_id": "turn", "turn_token_usage": { "output_tokens": 50 } }),
            start,
        ));
        parser.consume(&event(
            "event_msg",
            json!({ "type": "task_complete", "turn_id": "turn", "started_at": start, "completed_at": end, "duration_ms": 5000 }),
            end,
        ))
    };
    // A tail that began mid-turn never saw the start (nor, usually, the context).
    let mut tail = crate::parser::CodexEventParser::new("file".into());
    tail.begin_mid_file();
    assert!(feed(&mut tail, false).is_none());
    let mut archive = crate::parser::CodexEventParser::new("file".into());
    let found = feed(&mut archive, true).unwrap();
    assert_eq!(found.model.as_deref(), Some("gpt-test"));
    assert_eq!(found.output_tokens, 50);
}

// --- Response speed (response-v1) -----------------------------------------------------------

fn tool_result(at: &str, id: &str) -> Vec<u8> {
    claude_user(
        at,
        id,
        json!([{"type": "tool_result", "tool_use_id": "t", "content": "ok"}]),
    )
}

fn model_message(at: &str, id: &str, model: &str, stop: &str, tokens: i64) -> Vec<u8> {
    claude_message(
        "assistant",
        "assistant",
        at,
        id,
        model,
        stop,
        tokens,
        json!([]),
    )
}

#[test]
fn claude_tool_loop_responses_start_at_the_latest_user_record() {
    let mut parser = claude_parser();
    parser.consume_settled(&claude_user("2026-10-03T10:00:00Z", "human", json!("go")));
    parser.consume_settled(&assistant("2026-10-03T10:00:05Z", "msg-a", "tool_use", 300));
    parser.consume_settled(&tool_result("2026-10-03T10:00:20Z", "result-a"));
    parser.consume_settled(&assistant("2026-10-03T10:00:28Z", "msg-b", "tool_use", 400));
    parser.consume_settled(&tool_result("2026-10-03T10:01:00Z", "result-b"));
    let turn = parser
        .consume_settled(&assistant("2026-10-03T10:01:10Z", "msg-c", "end_turn", 600))
        .unwrap();
    // 5 s, 8 s and 10 s requests: each response runs from its trigger to its last record.
    assert_eq!(turn.output_tokens, 1_300);
    assert_eq!(turn.response_output_tokens, Some(1_300));
    assert_eq!(turn.response_duration_seconds, Some(23.0));
    assert_eq!(turn.response_count, Some(3));
    let live = parser.take_responses();
    assert_eq!(live.len(), 3);
    assert_eq!(
        live.iter().map(|r| r.duration_seconds).collect::<Vec<_>>(),
        [5.0, 8.0, 10.0]
    );
    assert_eq!(live[0].speed(), 60.0);
    assert_eq!(live[2].completed_at, time("2026-10-03T10:01:10Z"));
    assert_eq!(live[0].model.as_deref(), Some("claude-model"));
    assert_eq!(live[0].client, CLAUDE_CLIENT);
    assert_eq!(live[0].source_kind.as_deref(), Some("primary"));
    assert_eq!(live[0].metric_version, CLAUDE_METRIC_VERSION);
    assert_eq!(live[0].reasoning_effort.as_deref(), Some("high"));
    assert_eq!(live[0].provider.as_deref(), Some("unknown"));
    let ids: HashSet<_> = live.iter().map(|r| r.id.clone()).collect();
    assert_eq!(ids.len(), 3);
    assert!(parser.take_responses().is_empty());
}

#[test]
fn claude_response_ends_at_the_last_record_of_a_multi_block_message() {
    let mut parser = claude_parser();
    parser.consume(&claude_user("2026-10-03T10:00:00Z", "human", json!("go")));
    // Thinking, text and tool-use blocks of one API response are separate records.
    parser.consume(&assistant("2026-10-03T10:00:03Z", "msg-a", "tool_use", 2));
    parser.consume(&assistant("2026-10-03T10:00:08Z", "msg-a", "tool_use", 120));
    parser.consume(&assistant("2026-10-03T10:00:12Z", "msg-a", "tool_use", 400));
    assert!(
        parser.take_responses().is_empty(),
        "the response is still open"
    );
    // The next request's first record shows the response is over.
    parser.consume(&tool_result("2026-10-03T10:00:30Z", "result"));
    parser.consume(&assistant("2026-10-03T10:00:35Z", "msg-b", "tool_use", 50));
    let live = parser.take_responses();
    assert_eq!(live.len(), 1);
    assert_eq!(live[0].duration_seconds, 12.0);
    assert_eq!(live[0].output_tokens, 400);
}

#[test]
fn claude_meta_and_notification_records_are_request_triggers() {
    let mut parser = claude_parser();
    parser.consume_settled(&claude_user("2026-10-03T10:00:00Z", "human", json!("go")));
    parser.consume_settled(&assistant("2026-10-03T10:00:05Z", "msg-a", "tool_use", 300));
    parser.consume_settled(&user_with(
        "2026-10-03T10:00:30Z",
        "note",
        json!({"origin": {"kind": "task-notification"}}),
    ));
    parser.consume_settled(&user_with(
        "2026-10-03T10:00:31Z",
        "meta",
        json!({"isMeta": true}),
    ));
    let turn = parser
        .consume_settled(&assistant("2026-10-03T10:00:36Z", "msg-b", "end_turn", 500))
        .unwrap();
    let live = parser.take_responses();
    assert_eq!(live[1].duration_seconds, 5.0);
    assert_eq!(turn.response_duration_seconds, Some(10.0));
}

#[test]
fn claude_responses_below_the_floor_over_the_cap_or_synthetic_never_qualify() {
    let mut parser = claude_parser();
    parser.consume_settled(&claude_user("2026-10-03T10:00:00Z", "human", json!("go")));
    parser.consume_settled(&assistant("2026-10-03T10:00:05Z", "short", "tool_use", 199));
    parser.consume_settled(&tool_result("2026-10-03T10:00:10Z", "r1"));
    // Exactly 600 s qualifies; one more second does not.
    parser.consume_settled(&assistant("2026-10-03T10:10:10Z", "edge", "tool_use", 200));
    parser.consume_settled(&tool_result("2026-10-03T10:10:20Z", "r2"));
    parser.consume_settled(&assistant("2026-10-03T10:20:21Z", "slow", "tool_use", 900));
    parser.consume_settled(&tool_result("2026-10-03T10:20:30Z", "r3"));
    parser.consume_settled(&model_message(
        "2026-10-03T10:20:34Z",
        "synthetic",
        "<synthetic>",
        "tool_use",
        900,
    ));
    parser.consume_settled(&tool_result("2026-10-03T10:20:40Z", "r4"));
    let live: Vec<_> = parser.take_responses();
    assert_eq!(live.len(), 1);
    assert_eq!(live[0].output_tokens, 200);
    assert_eq!(live[0].duration_seconds, 600.0);

    // A turn without any qualifying response reports no response fields.
    let mut quiet = claude_parser();
    quiet.consume_settled(&claude_user("2026-10-03T10:00:00Z", "human", json!("go")));
    let turn = quiet
        .consume_settled(&assistant("2026-10-03T10:00:05Z", "tiny", "end_turn", 100))
        .unwrap();
    assert_eq!(turn.response_output_tokens, None);
    assert_eq!(turn.response_duration_seconds, None);
    assert_eq!(turn.response_count, None);
}

#[test]
fn claude_discarded_turns_report_no_response_fields() {
    let mut parser = claude_parser();
    parser.consume(&claude_user("2026-10-03T10:00:00Z", "human", json!("go")));
    parser.consume(&assistant("2026-10-03T10:00:05Z", "msg-a", "tool_use", 300));
    parser.consume(&claude_user(
        "2026-10-03T10:00:09Z",
        "stop",
        json!("[Request interrupted by user]"),
    ));
    assert!(parser
        .consume(&assistant("2026-10-03T10:00:15Z", "msg-b", "end_turn", 500))
        .is_none());

    // A synthetic message invalidates the whole turn.
    let mut synthetic = claude_parser();
    synthetic.consume(&claude_user("2026-10-03T10:00:00Z", "human", json!("go")));
    synthetic.consume(&assistant("2026-10-03T10:00:05Z", "msg-a", "tool_use", 300));
    synthetic.consume(&tool_result("2026-10-03T10:00:08Z", "r"));
    synthetic.consume(&model_message(
        "2026-10-03T10:00:12Z",
        "fake",
        "<synthetic>",
        "tool_use",
        50,
    ));
    synthetic.consume(&tool_result("2026-10-03T10:00:14Z", "r2"));
    assert!(synthetic
        .consume(&assistant("2026-10-03T10:00:20Z", "msg-c", "end_turn", 500))
        .is_none());
}

#[test]
fn claude_responses_need_an_observed_trigger() {
    let mut parser = claude_parser();
    // A reader that joined mid-file sees an assistant record before any user record.
    parser.consume(&assistant(
        "2026-10-03T10:00:05Z",
        "orphan",
        "tool_use",
        300,
    ));
    parser.consume(&tool_result("2026-10-03T10:00:08Z", "r"));
    assert!(parser.take_responses().is_empty());
    parser.consume(&assistant("2026-10-03T10:00:14Z", "next", "tool_use", 300));
    parser.consume(&tool_result("2026-10-03T10:00:20Z", "r2"));
    parser.flush_pending(time("2026-10-03T10:00:21Z"), true);
    assert_eq!(parser.take_responses().len(), 1);
}

#[test]
fn claude_subagent_responses_are_labelled_and_identified_apart() {
    let session = "11111111-2222-4333-8444-555555555555";
    let agent = "a1b2c3d4e5f60718";
    let mut parser = crate::claude_parser::ClaudeTranscriptParser::new_subagent("file".into());
    parser.consume_settled(&as_subagent(
        claude_user("2026-10-03T10:00:00Z", "task", json!("task")),
        session,
        agent,
    ));
    let turn = parser
        .consume_settled(&as_subagent(
            assistant("2026-10-03T10:00:04Z", "sub-1", "end_turn", 400),
            session,
            agent,
        ))
        .unwrap();
    assert_eq!(turn.metric_version, CLAUDE_SUBAGENT_METRIC_VERSION);
    assert_eq!(turn.response_count, Some(1));
    let live = parser.take_responses();
    assert_eq!(live[0].source_kind.as_deref(), Some("subagent"));
    assert_eq!(live[0].speed(), 100.0);
}

#[test]
fn claude_bedrock_region_comes_from_the_inference_profile_prefix() {
    let run = |model: &str, message_id: &str| {
        let mut parser = claude_parser();
        parser.consume_settled(&claude_user("2026-10-03T10:00:00Z", "human", json!("go")));
        parser
            .consume_settled(&model_message(
                "2026-10-03T10:00:05Z",
                message_id,
                model,
                "end_turn",
                300,
            ))
            .unwrap()
    };
    let bedrock_id = "msg_bdrk_01ABCDEFGHIJKL";
    let eu = run("eu.anthropic.claude-sonnet-4-5-20250929-v1:0", bedrock_id);
    assert_eq!(eu.provider.as_deref(), Some("amazon-bedrock"));
    assert_eq!(eu.model.as_deref(), Some("claude-sonnet-4-5-20250929"));
    assert_eq!(eu.provider_region.as_deref(), Some("eu"));
    assert_eq!(
        run(
            "us-gov.anthropic.claude-sonnet-4-5-20250929-v1:0",
            bedrock_id
        )
        .provider_region
        .as_deref(),
        Some("us-gov")
    );
    assert_eq!(
        run("global.anthropic.claude-opus-4-6-v1", bedrock_id)
            .provider_region
            .as_deref(),
        Some("global")
    );
    // No prefix, or a prefix outside the allowlist, is an unknown region.
    for model in [
        "anthropic.claude-3-haiku-20240307-v1:0",
        "xx.anthropic.claude-3-haiku-20240307-v1:0",
    ] {
        assert_eq!(
            run(model, bedrock_id).provider_region.as_deref(),
            Some("unknown")
        );
    }
    // Other routes carry no region, even when the model id has a prefix.
    assert_eq!(
        run("claude-sonnet-4-5", "msg_vrtx_01ABCDEFGHIJKL").provider_region,
        None
    );
    assert_eq!(
        run("us.anthropic.claude-sonnet-4-5-20250929-v1:0", "plain-id").provider_region,
        None
    );
}

// --- Codex responses ---

fn codex_line(kind: &str, payload: Value, at: &str) -> Vec<u8> {
    event(kind, payload, at)
}

fn codex_item(payload: Value, at: &str) -> Vec<u8> {
    codex_line("response_item", payload, at)
}

fn codex_usage(at: &str, response: &str, response_tokens: i64, turn_tokens: i64) -> Vec<u8> {
    codex_line(
        "token_usage_record",
        json!({
            "turn_id": "turn-1",
            "response_id": response,
            "usage": {"output_tokens": response_tokens, "reasoning_output_tokens": 0},
            "turn_token_usage": {"output_tokens": turn_tokens, "reasoning_output_tokens": 0}
        }),
        at,
    )
}

fn codex_rollout() -> Vec<Vec<u8>> {
    vec![
        codex_line(
            "session_meta",
            json!({"id": "session-1", "cli_version": "0.159.2", "source": "cli", "model_provider": "openai"}),
            "2026-10-03T10:00:00.000Z",
        ),
        codex_line(
            "event_msg",
            json!({"type": "task_started", "turn_id": "turn-1"}),
            "2026-10-03T10:00:00.000Z",
        ),
        codex_line(
            "turn_context",
            json!({"turn_id": "turn-1", "model": "gpt-test", "effort": "high"}),
            "2026-10-03T10:00:00.100Z",
        ),
        // Developer context after the user message neither triggers nor responds.
        codex_item(
            json!({"type": "message", "role": "user"}),
            "2026-10-03T10:00:00.200Z",
        ),
        codex_item(
            json!({"type": "message", "role": "developer"}),
            "2026-10-03T10:00:00.300Z",
        ),
        // Response 1: 300 tokens from the user message (0.2 s) to its usage record (4.2 s).
        codex_item(json!({"type": "reasoning"}), "2026-10-03T10:00:02.000Z"),
        codex_item(json!({"type": "function_call"}), "2026-10-03T10:00:03.000Z"),
        codex_usage("2026-10-03T10:00:04.200Z", "resp-1", 300, 300),
        // Response 2: 150 tokens (too short), triggered by the tool output.
        codex_item(
            json!({"type": "function_call_output"}),
            "2026-10-03T10:00:10.000Z",
        ),
        codex_item(json!({"type": "reasoning"}), "2026-10-03T10:00:11.000Z"),
        codex_usage("2026-10-03T10:00:12.000Z", "resp-2", 150, 450),
        // Response 3: 250 tokens from the next tool output (20 s) to 25 s.
        codex_item(
            json!({"type": "custom_tool_call_output"}),
            "2026-10-03T10:00:20.000Z",
        ),
        codex_item(
            json!({"type": "message", "role": "assistant"}),
            "2026-10-03T10:00:24.000Z",
        ),
        codex_usage("2026-10-03T10:00:25.000Z", "resp-3", 250, 700),
        codex_line(
            "event_msg",
            json!({"type": "task_complete", "turn_id": "turn-1", "duration_ms": 25000, "time_to_first_token_ms": 900}),
            "2026-10-03T10:00:25.100Z",
        ),
    ]
}

#[test]
fn codex_responses_use_the_per_response_usage_between_trigger_and_usage_record() {
    let mut parser = crate::parser::CodexEventParser::new("file".into());
    let mut turns = Vec::new();
    for line in codex_rollout() {
        turns.extend(parser.consume(&line));
    }
    assert_eq!(turns.len(), 1);
    let turn = &turns[0];
    // The turn keeps its cumulative total; the response fields count only qualifying ones.
    assert_eq!(turn.output_tokens, 700);
    assert_eq!(turn.response_output_tokens, Some(550));
    assert!((turn.response_duration_seconds.unwrap() - 9.0).abs() < 1e-9);
    assert_eq!(turn.response_count, Some(2));
    assert_eq!(turn.parser_version, "codex-rollout-v2");
    let live = parser.take_responses();
    assert_eq!(live.len(), 2);
    assert_eq!(live[0].output_tokens, 300);
    assert!((live[0].duration_seconds - 4.0).abs() < 1e-9);
    assert_eq!(live[0].completed_at, time("2026-10-03T10:00:04.200Z"));
    assert_eq!(live[0].model.as_deref(), Some("gpt-test"));
    assert_eq!(live[0].provider.as_deref(), Some("openai"));
    assert_eq!(live[0].client, "codex");
    assert_eq!(live[0].source_kind.as_deref(), Some("primary"));
    assert_eq!(live[0].reasoning_effort.as_deref(), Some("high"));
    assert_eq!(live[1].output_tokens, 250);
    assert!((live[1].duration_seconds - 5.0).abs() < 1e-9);
}

#[test]
fn codex_responses_skip_duplicates_agent_sessions_and_unobserved_starts() {
    let mut parser = crate::parser::CodexEventParser::new("file".into());
    for line in codex_rollout().into_iter().take(8) {
        parser.consume(&line);
    }
    // A repeated usage record for the same response id must not count twice.
    parser.consume(&codex_usage("2026-10-03T10:00:04.300Z", "resp-1", 300, 300));
    assert_eq!(parser.take_responses().len(), 1);

    // Agent sessions never contribute.
    let mut agent = crate::parser::CodexEventParser::new("file".into());
    agent.consume(&codex_line(
        "session_meta",
        json!({"id": "agent", "parent_thread_id": "parent", "source": "cli"}),
        "2026-10-03T10:00:00Z",
    ));
    for line in codex_rollout().into_iter().skip(1) {
        agent.consume(&line);
    }
    assert!(agent.take_responses().is_empty());

    // Usage whose trigger was never observed (a reader that joined mid-turn) is not timed.
    let mut midway = crate::parser::CodexEventParser::new("file".into());
    midway.consume(&codex_item(
        json!({"type": "reasoning"}),
        "2026-10-03T10:00:02.000Z",
    ));
    midway.consume(&codex_usage("2026-10-03T10:00:04.200Z", "resp-1", 300, 300));
    assert!(midway.take_responses().is_empty());
}

#[test]
fn codex_turns_without_qualifying_responses_report_none() {
    let mut parser = crate::parser::CodexEventParser::new("file".into());
    let mut turn = None;
    for line in [
        codex_line(
            "event_msg",
            json!({"type": "task_started", "turn_id": "turn-1"}),
            "2026-10-03T10:00:00Z",
        ),
        codex_item(json!({"type": "reasoning"}), "2026-10-03T10:00:01Z"),
        codex_usage("2026-10-03T10:00:02Z", "resp-1", 50, 50),
        codex_line(
            "event_msg",
            json!({"type": "task_complete", "turn_id": "turn-1", "duration_ms": 2000}),
            "2026-10-03T10:00:02.100Z",
        ),
    ] {
        turn = turn.or(parser.consume(&line));
    }
    let turn = turn.unwrap();
    assert_eq!(turn.response_output_tokens, None);
    assert_eq!(turn.response_duration_seconds, None);
    assert_eq!(turn.response_count, None);
}

// --- Live stream plumbing ---

fn live_response(
    id: &str,
    at: &str,
    model: &str,
    tokens: i64,
    seconds: f64,
) -> crate::ResponseMetric {
    crate::ResponseMetric {
        id: id.into(),
        completed_at: time(at),
        model: Some(model.into()),
        provider: Some("anthropic".into()),
        client: CLAUDE_CLIENT.into(),
        source_kind: Some("primary".into()),
        metric_version: "response-v1".into(),
        reasoning_effort: None,
        output_tokens: tokens,
        duration_seconds: seconds,
    }
}

#[test]
fn live_stream_keeps_new_qualifying_unique_responses_in_a_bounded_buffer() {
    let started = time("2026-10-03T10:00:00Z");
    let now = time("2026-10-03T12:00:00Z");
    let mut live = crate::LiveResponses::new(started);
    assert!(live.push(
        vec![
            live_response("before-launch", "2026-10-03T09:59:59Z", "m", 300, 3.0),
            live_response("short", "2026-10-03T10:30:00Z", "m", 100, 1.0),
            live_response("slow", "2026-10-03T10:30:00Z", "m", 300, 601.0),
            live_response("future", "2026-10-03T13:00:00Z", "m", 300, 3.0),
            live_response("ok", "2026-10-03T10:31:00Z", "m", 300, 3.0),
            live_response("ok", "2026-10-03T10:31:00Z", "m", 300, 3.0),
        ],
        now,
    ));
    assert_eq!(live.len(), 1);
    assert!(!live.push(
        vec![live_response("ok", "2026-10-03T10:31:00Z", "m", 300, 3.0)],
        now
    ));

    let many: Vec<_> = (0..250)
        .map(|index| {
            live_response(
                &format!("r{index}"),
                "2026-10-03T11:00:00Z",
                "m",
                300,
                3.0 + index as f64 / 1000.0,
            )
        })
        .collect();
    live.push(many, now);
    assert_eq!(live.len(), crate::LIVE_CAPACITY);
    // Evicted ids can come back; retained ones cannot be added twice.
    assert!(!live.push(
        vec![live_response(
            "r249",
            "2026-10-03T11:00:00Z",
            "m",
            300,
            3.249
        )],
        now
    ));
}

#[test]
fn live_value_is_the_median_of_the_last_five_responses_within_ten_minutes() {
    let started = time("2026-10-03T10:00:00Z");
    let now = time("2026-10-03T10:20:00Z");
    let mut live = crate::LiveResponses::new(started);
    // Speeds 10..60 tok/s, one per minute; only the newest five count.
    let responses: Vec<_> = (1..=6)
        .map(|index| {
            live_response(
                &format!("r{index}"),
                &format!("2026-10-03T10:{:02}:00Z", 10 + index),
                "model-a",
                300,
                300.0 / (index as f64 * 10.0),
            )
        })
        .collect();
    live.push(responses, now);
    let scope = crate::LiveScope {
        model: Some("model-a".into()),
        provider: Some("anthropic".into()),
        client: None,
    };
    let value = live.value(now, &scope).unwrap();
    assert_eq!(value.count, 5);
    assert_eq!(value.speed, 40.0);
    assert_eq!(value.last_at, time("2026-10-03T10:16:00Z"));
    // Only responses of the last ten minutes: 10:16 is the last, so 10:26 sees none.
    assert!(live.value(time("2026-10-03T10:26:01Z"), &scope).is_none());
    // Four responses in the window give their median (average of the middle pair).
    let four = live.value(time("2026-10-03T10:24:00Z"), &scope).unwrap();
    assert_eq!(four.count, 3);
    // Other models and tools do not count.
    let other = crate::LiveScope {
        model: Some("model-b".into()),
        ..scope.clone()
    };
    assert!(live.value(now, &other).is_none());
    let tool = crate::LiveScope {
        client: Some("codex".into()),
        ..scope
    };
    assert!(live.value(now, &tool).is_none());
}

#[test]
fn live_value_averages_the_middle_pair_of_an_even_count() {
    let mut live = crate::LiveResponses::new(time("2026-10-03T10:00:00Z"));
    let now = time("2026-10-03T10:10:00Z");
    live.push(
        vec![
            live_response("a", "2026-10-03T10:08:00Z", "m", 300, 10.0),
            live_response("b", "2026-10-03T10:09:00Z", "m", 600, 10.0),
        ],
        now,
    );
    let scope = crate::LiveScope {
        model: Some("m".into()),
        provider: Some("anthropic".into()),
        client: None,
    };
    assert_eq!(live.value(now, &scope).unwrap().speed, 45.0);
}

#[test]
fn monitor_live_responses_come_only_from_the_recent_tail_never_history_replay() {
    let temp = TestDir::new();
    let projects = temp.path().join("projects").join("project");
    fs::create_dir_all(&projects).unwrap();
    let path = projects.join("session.jsonl");
    let mut lines = Vec::new();
    let padding = "x".repeat(2_000);
    let turn = |lines: &mut Vec<Vec<u8>>, prefix: &str, start: &str, end: &str| {
        lines.push(claude_user(start, &format!("{prefix}-human"), json!("go")));
        lines.push(assistant(end, &format!("{prefix}-answer"), "end_turn", 500));
    };
    // The first turn's records sit before the 256 KiB tail window.
    turn(
        &mut lines,
        "old",
        "2026-10-03T10:00:00Z",
        "2026-10-03T10:00:05Z",
    );
    for index in 0..200 {
        lines.push(
            serde_json::to_vec(&json!({
                "type": "summary",
                "timestamp": "2026-10-03T10:01:00Z",
                "isSidechain": false,
                "userType": "external",
                "note": format!("{index}{padding}")
            }))
            .unwrap(),
        );
    }
    // The newest turn follows a sync boundary the tail reader can recognise.
    lines.push(claude_user(
        "2026-10-03T10:10:00Z",
        "new-human",
        json!("go"),
    ));
    lines.push(assistant(
        "2026-10-03T10:10:06Z",
        "new-answer",
        "tool_use",
        600,
    ));
    lines.push(tool_result("2026-10-03T10:10:08Z", "new-result"));
    lines.push(assistant(
        "2026-10-03T10:10:12Z",
        "new-final",
        "end_turn",
        400,
    ));
    fs::write(&path, jsonl(&lines)).unwrap();
    assert!(fs::metadata(&path).unwrap().len() > Monitor::RECENT_TAIL_BYTES);

    let now = time("2026-10-03T10:11:00Z");
    let mut monitor = Monitor::new_claude(temp.path().join("projects"));
    let mut live = Vec::new();
    for _ in 0..8 {
        monitor.poll(now).unwrap();
        live.extend(monitor.take_live_responses());
    }
    // The tail reader starts mid-file without the prompt; it reports the answers it can time.
    let tokens: Vec<i64> = live.iter().map(|response| response.output_tokens).collect();
    assert!(!tokens.is_empty());
    assert!(live
        .iter()
        .all(|response| response.completed_at >= time("2026-10-03T10:10:00Z")));
    assert!(live.iter().all(|response| response.id.len() == 64));
}

// --- Auto selector ---

fn at(minutes: i64) -> DateTime<Utc> {
    at_seconds(minutes * 60)
}

fn at_seconds(seconds: i64) -> DateTime<Utc> {
    time("2026-10-03T10:00:00Z") + Duration::seconds(seconds)
}

fn live_for(model: &str, client: &str, minutes: i64, tokens: i64) -> crate::ResponseMetric {
    live_for_seconds(model, client, minutes * 60, tokens)
}

fn live_for_seconds(model: &str, client: &str, seconds: i64, tokens: i64) -> crate::ResponseMetric {
    let mut response = live_response(
        &format!("{model}-{client}-{seconds}-{tokens}"),
        "2026-10-03T10:00:00Z",
        model,
        tokens,
        tokens as f64 / 50.0,
    );
    response.completed_at = at_seconds(seconds);
    response.client = client.into();
    response.provider = Some(
        if client == "codex" {
            "openai"
        } else {
            "anthropic"
        }
        .into(),
    );
    response
}

fn key(model: &str, provider: &str) -> crate::ModelKey {
    crate::ModelKey {
        model: Some(model.into()),
        provider: Some(provider.into()),
    }
}

#[test]
fn auto_selector_adopts_the_busiest_model_then_resists_flapping() {
    let mut selector = crate::AutoSelector::new();
    let mut live = vec![live_for_seconds("claude-a", "claude-code", 60, 600)];
    assert_eq!(
        selector.update(at_seconds(60), &live, None),
        Some(&key("claude-a", "anthropic"))
    );
    // A challenger that is busier for less than thirty seconds does not take over.
    live.push(live_for_seconds("gpt-b", "codex", 70, 2_000));
    assert_eq!(
        selector.update(at_seconds(70), &live, None),
        Some(&key("claude-a", "anthropic"))
    );
    assert_eq!(
        selector.update(at_seconds(99), &live, None),
        Some(&key("claude-a", "anthropic"))
    );
    // Leading continuously for thirty seconds: takeover.
    assert_eq!(
        selector.update(at_seconds(100), &live, None),
        Some(&key("gpt-b", "openai"))
    );
}

#[test]
fn auto_selector_restarts_the_lead_timer_when_the_leader_changes() {
    let mut selector = crate::AutoSelector::new();
    let mut live = vec![live_for_seconds("claude-a", "claude-code", 60, 3_000)];
    selector.update(at_seconds(60), &live, None);
    live.push(live_for_seconds("gpt-b", "codex", 70, 4_000));
    selector.update(at_seconds(70), &live, None);
    // Model A becomes the leader again before B led for thirty seconds.
    live.push(live_for_seconds("claude-a", "claude-code", 80, 5_000));
    assert_eq!(
        selector.update(at_seconds(80), &live, None),
        Some(&key("claude-a", "anthropic"))
    );
    // B leading anew starts a fresh thirty second timer.
    live.push(live_for_seconds("gpt-b", "codex", 100, 9_000));
    assert_eq!(
        selector.update(at_seconds(100), &live, None),
        Some(&key("claude-a", "anthropic"))
    );
    assert_eq!(
        selector.update(at_seconds(129), &live, None),
        Some(&key("claude-a", "anthropic"))
    );
    assert_eq!(
        selector.update(at_seconds(130), &live, None),
        Some(&key("gpt-b", "openai"))
    );
}

#[test]
fn auto_selector_switches_at_once_when_the_active_model_went_quiet() {
    let mut selector = crate::AutoSelector::new();
    let mut live = vec![live_for_seconds("claude-a", "claude-code", 0, 600)];
    selector.update(at_seconds(60), &live, None);
    live.push(live_for_seconds("gpt-b", "codex", 200, 300));
    // A's only response left the three minute window: B takes over without waiting.
    assert_eq!(
        selector.update(at_seconds(210), &live, None),
        Some(&key("gpt-b", "openai"))
    );
}

#[test]
fn auto_selector_keeps_a_model_that_still_has_a_response_in_the_window() {
    let mut selector = crate::AutoSelector::new();
    let mut live = vec![live_for_seconds("claude-a", "claude-code", 0, 300)];
    selector.update(at_seconds(10), &live, None);
    live.push(live_for_seconds("gpt-b", "codex", 100, 2_000));
    // A's response is 170 s old: still in the window, so B must lead for 30 s first.
    assert_eq!(
        selector.update(at_seconds(170), &live, None),
        Some(&key("claude-a", "anthropic"))
    );
    assert_eq!(
        selector.update(at_seconds(179), &live, None),
        Some(&key("claude-a", "anthropic"))
    );
    // 181 s: A has left the window and B has led for 11 s; the quiet model is replaced at once.
    assert_eq!(
        selector.update(at_seconds(181), &live, None),
        Some(&key("gpt-b", "openai"))
    );
}

#[test]
fn auto_selector_falls_back_when_nothing_is_live() {
    let mut selector = crate::AutoSelector::new();
    let live = vec![live_for("claude-a", "claude-code", 0, 600)];
    assert!(selector.update(at(1), &live, None).is_some());
    assert!(selector.update(at(4), &live, None).is_none());
    assert!(selector.active().is_none());

    let mut older = metric("older", at(-120));
    older.model = Some("with-responses".into());
    older.response_count = Some(2);
    let mut newest = metric("newest", at(-10));
    newest.model = Some("newest-without".into());
    let turns = vec![newest.clone(), older.clone()];
    assert_eq!(
        crate::fallback_model(&turns, None)
            .unwrap()
            .model
            .as_deref(),
        Some("with-responses")
    );
    older.response_count = None;
    assert_eq!(
        crate::fallback_model(&[newest, older], None)
            .unwrap()
            .model
            .as_deref(),
        Some("newest-without")
    );
    assert!(crate::fallback_model(&[], None).is_none());
}

#[test]
fn auto_selector_within_a_coding_tool_ignores_other_tools() {
    let mut selector = crate::AutoSelector::new();
    let live = vec![
        live_for("claude-a", "claude-code", 1, 600),
        live_for("gpt-b", "codex", 1, 9_000),
    ];
    assert_eq!(
        selector.update(at(2), &live, Some("claude-code")),
        Some(&key("claude-a", "anthropic"))
    );
    assert_eq!(
        selector.update(at(2), &live, Some("codex")),
        Some(&key("gpt-b", "openai"))
    );
    assert_eq!(
        selector.update(at(2), &live, None),
        Some(&key("gpt-b", "openai"))
    );
    assert!(selector.update(at(2), &live, Some("grok-build")).is_none());
}

#[test]
fn a_tiny_codex_check_in_never_wins_over_an_active_claude_session() {
    let mut selector = crate::AutoSelector::new();
    let mut live = Vec::new();
    for minute in 0..30 {
        // Claude answers every minute; Codex pings every five minutes with 118 tokens.
        live.push(live_for("claude-a", "claude-code", minute, 400));
        if minute % 5 == 0 {
            live.push(live_for("gpt-b", "codex", minute, 118));
        }
        assert_eq!(
            selector.update(at(minute), &live, None),
            Some(&key("claude-a", "anthropic")),
            "minute {minute}"
        );
    }
    // Even a stream made only of check-ins is not a candidate.
    let mut quiet = crate::AutoSelector::new();
    assert!(quiet
        .update(at(1), &[live_for("gpt-b", "codex", 1, 118)], None)
        .is_none());
}

#[test]
fn selection_modes_parse_and_legacy_latest_means_auto() {
    use crate::SelectionMode;
    assert_eq!(
        SelectionMode::parse("latest"),
        Some(SelectionMode::Auto { tool: None })
    );
    assert_eq!(SelectionMode::normalize("latest").as_deref(), Some("auto"));
    assert_eq!(
        SelectionMode::parse("auto:claude-code"),
        Some(SelectionMode::Auto {
            tool: Some("claude-code".into())
        })
    );
    assert_eq!(SelectionMode::parse("auto:unknown-tool"), None);
    assert_eq!(SelectionMode::parse("all"), Some(SelectionMode::All));
    assert_eq!(
        SelectionMode::parse(r#"model:["gpt-5","openai"]"#),
        Some(SelectionMode::Model(key("gpt-5", "openai")))
    );
    assert_eq!(SelectionMode::parse(r#"model:["gpt-5"]"#), None);
    let cohort =
        json!(["codex", null, "p", "m", "gpt", "openai", null, "high", "primary"]).to_string();
    assert_eq!(
        SelectionMode::parse(&cohort),
        Some(SelectionMode::Cohort(cohort.clone()))
    );
    // The pre-0.1.14 eight-part cohort identity is no longer a valid selection.
    let legacy = json!(["codex", null, "p", "m", "gpt", "openai", "high", "primary"]).to_string();
    assert_eq!(SelectionMode::parse(&legacy), None);
    assert_eq!(SelectionMode::parse("junk"), None);
}

#[test]
fn provider_badge_follows_explicit_provider_then_model_family() {
    use crate::ProviderBadge::*;
    assert_eq!(
        crate::ProviderBadge::of(Some("claude-opus-5-5"), None),
        Anthropic
    );
    assert_eq!(
        crate::ProviderBadge::of(Some("claude-opus-5-5"), Some("amazon-bedrock")),
        Anthropic
    );
    assert_eq!(
        crate::ProviderBadge::of(Some("claude-sonnet-4-5"), Some("google-vertex")),
        Anthropic
    );
    assert_eq!(crate::ProviderBadge::of(None, Some("anthropic")), Anthropic);
    assert_eq!(
        crate::ProviderBadge::of(Some("gpt-5-codex"), Some("unknown")),
        OpenAi
    );
    assert_eq!(crate::ProviderBadge::of(Some("o3-mini"), None), OpenAi);
    assert_eq!(crate::ProviderBadge::of(Some("o4"), None), OpenAi);
    assert_eq!(
        crate::ProviderBadge::of(Some("my-codex-model"), None),
        OpenAi
    );
    assert_eq!(crate::ProviderBadge::of(None, Some("openai")), OpenAi);
    assert_eq!(crate::ProviderBadge::of(Some("grok-4"), None), Xai);
    assert_eq!(crate::ProviderBadge::of(Some("anything"), Some("xai")), Xai);
    assert_eq!(crate::ProviderBadge::of(Some("omega"), None), Unknown);
    assert_eq!(crate::ProviderBadge::of(None, None), Unknown);
    assert_eq!(
        crate::ProviderBadge::of(Some("mystery"), Some("amazon-bedrock")),
        Unknown
    );
    assert_eq!(Anthropic.letter(), Some('A'));
    assert_eq!(Unknown.letter(), None);
}

// --- Sharing validation ---

fn response_metric(tokens: i64, seconds: f64, count: i64) -> TurnMetric {
    let mut turn = TurnMetric::new_observed(
        "local-digest".into(),
        time("2026-10-03T10:03:47Z"),
        Some("claude-opus-4-1".into()),
        1_000,
        100.0,
        Some("1.2.3".into()),
        None,
        Some("primary".into()),
        Some("anthropic".into()),
        None,
        CLAUDE_CLIENT,
        CLAUDE_PARSER_VERSION,
        CLAUDE_METRIC_VERSION,
    );
    turn.response_output_tokens = Some(tokens);
    turn.response_duration_seconds = Some(seconds);
    turn.response_count = Some(count);
    turn.delegated_output_tokens = Some(0);
    turn
}

#[test]
fn shared_samples_carry_valid_response_fields_and_drop_inconsistent_ones() {
    let share = |turn: &TurnMetric| crate::SharedSample::from_metric(turn, Uuid::new_v4()).unwrap();
    let good = share(&response_metric(900, 20.0, 3));
    assert_eq!(good.response_output_tokens, Some(900));
    assert_eq!(good.response_duration_ms, Some(20_000.0));
    assert_eq!(good.response_count, Some(3));
    let json = serde_json::to_value(&good).unwrap();
    assert_eq!(json["responseOutputTokens"], 900);
    // Exactly 200 tokens per counted response is the inclusive boundary.
    assert_eq!(
        share(&response_metric(1_000, 20.0, 5)).response_count,
        Some(5)
    );

    // Every rejection removes all three fields but keeps the sample itself.
    for turn in [
        response_metric(1_001, 20.0, 1), // more tokens than the turn
        response_metric(900, 101.0, 1),  // longer than the turn
        response_metric(900, 0.4, 1),    // above 2000 tok/s
        response_metric(900, 20.0, 0),   // no responses
        response_metric(999, 20.0, 5),   // fewer than 200 tokens per counted response
    ] {
        let sample = share(&turn);
        assert_eq!(
            (
                sample.response_output_tokens,
                sample.response_duration_ms,
                sample.response_count
            ),
            (None, None, None)
        );
        let json = serde_json::to_value(&sample).unwrap();
        assert!(json["responseOutputTokens"].is_null());
        assert!(json["responseDurationMs"].is_null());
        assert!(json["responseCount"].is_null());
    }
    // Exactly 2000 tok/s and a response as long as the turn are still valid.
    assert!(share(&response_metric(1_000, 0.5, 1))
        .response_count
        .is_some());
    assert!(share(&response_metric(900, 100.0, 1))
        .response_count
        .is_some());
    // Turns that never had response data serialise explicit nulls.
    let mut none = response_metric(900, 20.0, 1);
    none.response_output_tokens = None;
    none.response_duration_seconds = None;
    none.response_count = None;
    let json = serde_json::to_value(share(&none)).unwrap();
    assert!(json.as_object().unwrap().contains_key("responseCount"));
    assert!(json["responseCount"].is_null());
}

#[test]
fn shared_response_fields_follow_the_shared_timing_rule() {
    let share = |turn: &TurnMetric| crate::SharedSample::from_metric(turn, Uuid::new_v4());
    let long_turn = |tokens: i64, seconds: f64, count: i64| {
        let mut turn = response_metric(tokens, seconds, count);
        turn.output_tokens = 5_000;
        turn.duration_seconds = 5_000.0;
        turn
    };
    // At most 600 s per counted response.
    assert_eq!(
        share(&long_turn(1_000, 600.0, 1)).unwrap().response_count,
        Some(1)
    );
    assert_eq!(
        share(&long_turn(1_000, 700.0, 2)).unwrap().response_count,
        Some(2)
    );
    for turn in [
        long_turn(1_000, 601.0, 1), // longer than count * 600 s
        long_turn(1_000, 0.0, 1),   // no duration
        long_turn(1_000, -1.0, 1),  // negative duration
        long_turn(399, 10.0, 2),    // fewer than 200 tokens per counted response
        long_turn(1_000, f64::NAN, 1),
    ] {
        let sample = share(&turn).unwrap();
        assert_eq!(
            (
                sample.response_output_tokens,
                sample.response_duration_ms,
                sample.response_count
            ),
            (None, None, None)
        );
    }
    // A turn above the speed bound is a measurement error: nothing is shared.
    let mut too_fast = response_metric(900, 20.0, 1);
    too_fast.output_tokens = 1_000;
    too_fast.duration_seconds = 0.4;
    assert!(share(&too_fast).is_none());
    too_fast.duration_seconds = 0.5;
    assert!(share(&too_fast).is_some());
}

#[test]
fn shared_provider_region_is_present_only_for_bedrock() {
    let mut bedrock = response_metric(900, 20.0, 1);
    bedrock.provider = Some("amazon-bedrock".into());
    bedrock.provider_region = Some("apac".into());
    let json =
        serde_json::to_value(crate::SharedSample::from_metric(&bedrock, Uuid::new_v4()).unwrap())
            .unwrap();
    assert_eq!(json["providerRegion"], "apac");
    bedrock.provider_region = Some("mars".into());
    let json =
        serde_json::to_value(crate::SharedSample::from_metric(&bedrock, Uuid::new_v4()).unwrap())
            .unwrap();
    assert_eq!(json["providerRegion"], "unknown");
    bedrock.provider_region = None;
    let json =
        serde_json::to_value(crate::SharedSample::from_metric(&bedrock, Uuid::new_v4()).unwrap())
            .unwrap();
    assert_eq!(json["providerRegion"], "unknown");
    let mut anthropic = response_metric(900, 20.0, 1);
    anthropic.provider_region = Some("us".into());
    let json =
        serde_json::to_value(crate::SharedSample::from_metric(&anthropic, Uuid::new_v4()).unwrap())
            .unwrap();
    assert!(json["providerRegion"].is_null());
    assert!(json.as_object().unwrap().contains_key("providerRegion"));
}

#[test]
fn history_load_sanitizes_implausible_speeds_and_response_timing() {
    let temp = TestDir::new();
    let path = temp.path().join("history-v1.json");
    let now = time("2026-10-04T10:00:00Z");
    // The real defect: 336 tokens "in" 2 ms, inside a normal 14 s turn.
    let mut inflated = metric("inflated", now - Duration::hours(1));
    inflated.output_tokens = 336;
    inflated.duration_seconds = 14.0;
    inflated.response_output_tokens = Some(336);
    inflated.response_duration_seconds = Some(0.002);
    inflated.response_count = Some(1);
    // A whole turn above the bound is dropped.
    let mut impossible = metric("impossible", now - Duration::hours(2));
    impossible.output_tokens = 5_000;
    impossible.duration_seconds = 1.0;
    // Valid response timing and plain turns are untouched.
    let mut valid = metric("valid", now - Duration::hours(3));
    valid.output_tokens = 900;
    valid.duration_seconds = 30.0;
    valid.response_output_tokens = Some(900);
    valid.response_duration_seconds = Some(20.0);
    valid.response_count = Some(2);
    let plain = metric("plain", now - Duration::hours(4));
    fs::write(
        &path,
        serde_json::to_vec(&json!({
            "schemaVersion": 1,
            "records": [inflated, impossible, valid.clone(), plain.clone()]
        }))
        .unwrap(),
    )
    .unwrap();
    let loaded = History::load(&path, now).unwrap();
    let ids: Vec<_> = loaded.records().iter().map(|r| r.id.as_str()).collect();
    assert_eq!(ids, ["inflated", "valid", "plain"]);
    let cleaned = &loaded.records()[0];
    assert_eq!(cleaned.output_tokens, 336);
    assert_eq!(cleaned.response_output_tokens, None);
    assert_eq!(cleaned.response_duration_seconds, None);
    assert_eq!(cleaned.response_count, None);
    assert_eq!(loaded.records()[1], valid);
    assert_eq!(loaded.records()[2], plain);

    // The cleaned state is what gets saved next.
    loaded.save(&path).unwrap();
    assert_eq!(
        History::load(&path, now).unwrap().records(),
        loaded.records()
    );
    assert!(!fs::read_to_string(&path).unwrap().contains("impossible"));
}

#[test]
fn history_without_response_fields_still_decodes() {
    let mut legacy = serde_json::to_value(metric("legacy", time("2026-10-03T10:00:00Z"))).unwrap();
    let object = legacy.as_object_mut().unwrap();
    for key in [
        "responseOutputTokens",
        "responseDurationSeconds",
        "responseCount",
        "providerRegion",
        "delegatedOutputTokens",
    ] {
        object.remove(key);
    }
    let restored: TurnMetric = serde_json::from_value(legacy).unwrap();
    assert_eq!(restored.response_count, None);
    assert_eq!(restored.provider_region, None);
    // Records saved before 0.1.16 decode with attribution not final, and serialize it as null.
    assert_eq!(restored.delegated_output_tokens, None);
    assert!(serde_json::to_value(&restored).unwrap()["delegatedOutputTokens"].is_null());
}

fn block_message(at: &str, id: &str, stop: &str, tokens: i64, block: &str) -> Vec<u8> {
    claude_message(
        "assistant",
        "assistant",
        at,
        id,
        "claude-model",
        stop,
        tokens,
        json!([{ "type": block }]),
    )
}

#[test]
fn claude_final_answer_that_starts_with_thinking_ends_at_its_last_record() {
    let mut parser = claude_parser();
    parser.consume(&claude_user("2026-10-03T10:00:00Z", "human", json!("go")));
    // Thinking arrives first with a partial usage snapshot; the text, and the final usage, follow.
    assert!(parser
        .consume(&block_message(
            "2026-10-03T10:00:05Z",
            "msg-a",
            "end_turn",
            2,
            "thinking"
        ))
        .is_none());
    assert!(parser
        .consume(&block_message(
            "2026-10-03T10:00:17Z",
            "msg-a",
            "end_turn",
            1_700,
            "text"
        ))
        .is_none());
    // The text block does not end in thinking, so the end of the read closes the turn.
    let turn = parser
        .flush_pending(time("2026-10-03T10:00:18Z"), false)
        .unwrap();
    assert_eq!(turn.output_tokens, 1_700);
    assert_eq!(turn.duration_seconds, 17.0);
    assert_eq!(turn.completed_at, time("2026-10-03T10:00:17Z"));
    assert_eq!(turn.response_output_tokens, Some(1_700));
    assert_eq!(turn.response_duration_seconds, Some(17.0));
    let live = parser.take_responses();
    assert_eq!(live.len(), 1);
    assert_eq!(live[0].speed(), 100.0);
}

#[test]
fn claude_turn_waiting_for_its_text_closes_at_the_next_record_or_when_flushed() {
    // The next prompt closes the turn with what was written.
    let mut parser = claude_parser();
    parser.consume(&claude_user("2026-10-03T10:00:00Z", "human", json!("go")));
    parser.consume(&block_message(
        "2026-10-03T10:00:05Z",
        "msg-a",
        "end_turn",
        300,
        "thinking",
    ));
    let closed = parser
        .consume(&claude_user("2026-10-03T10:05:00Z", "next", json!("again")))
        .unwrap();
    assert_eq!(closed.output_tokens, 300);
    assert_eq!(closed.completed_at, time("2026-10-03T10:00:05Z"));

    // At the end of the readable file the pending turn is emitted without waiting.
    let mut flushed = claude_parser();
    flushed.consume(&claude_user("2026-10-03T10:00:00Z", "human", json!("go")));
    flushed.consume(&block_message(
        "2026-10-03T10:00:05Z",
        "msg-a",
        "end_turn",
        300,
        "thinking",
    ));
    assert!(flushed
        .flush_pending(time("2026-10-03T10:00:06Z"), true)
        .is_some());
    assert!(flushed
        .flush_pending(time("2026-10-03T10:00:06Z"), true)
        .is_none());
}

#[test]
fn claude_flush_completes_a_tool_call_response_but_never_a_thinking_one() {
    let mut parser = claude_parser();
    parser.consume(&claude_user("2026-10-03T10:00:00Z", "human", json!("go")));
    parser.consume(&block_message(
        "2026-10-03T10:00:03Z",
        "msg-a",
        "tool_use",
        120,
        "thinking",
    ));
    assert!(parser
        .flush_pending(time("2026-10-03T10:00:04Z"), false)
        .is_none());
    assert!(
        parser.take_responses().is_empty(),
        "thinking may be followed by more blocks"
    );
    parser.consume(&block_message(
        "2026-10-03T10:00:08Z",
        "msg-a",
        "tool_use",
        420,
        "tool_use",
    ));
    parser.flush_pending(time("2026-10-03T10:00:09Z"), false);
    let live = parser.take_responses();
    assert_eq!(live.len(), 1);
    assert_eq!(live[0].output_tokens, 420);
    assert_eq!(live[0].duration_seconds, 8.0);
}

#[test]
fn claude_terminal_turn_is_pending_and_same_message_records_update_it() {
    let mut parser = claude_parser();
    parser.consume(&claude_user("2026-10-03T10:00:00Z", "human", json!("go")));
    // Text, then more text of the same message: each record updates usage and the end.
    assert!(parser
        .consume(&block_message(
            "2026-10-03T10:00:05Z",
            "msg-a",
            "end_turn",
            300,
            "text"
        ))
        .is_none());
    assert!(parser
        .consume(&block_message(
            "2026-10-03T10:00:09Z",
            "msg-a",
            "end_turn",
            500,
            "text"
        ))
        .is_none());
    // A record of another message closes the turn with the latest usage and end.
    let turn = parser
        .consume(&block_message(
            "2026-10-03T10:00:20Z",
            "msg-b",
            "tool_use",
            50,
            "tool_use",
        ))
        .unwrap();
    assert_eq!(turn.output_tokens, 500);
    assert_eq!(turn.completed_at, time("2026-10-03T10:00:09Z"));
    assert_eq!(turn.response_duration_seconds, Some(9.0));
}

#[test]
fn claude_pending_thinking_turn_survives_a_poll_boundary_until_text_or_the_timeout() {
    let mut parser = claude_parser();
    parser.consume(&claude_user("2026-10-03T10:00:00Z", "human", json!("go")));
    parser.consume(&block_message(
        "2026-10-03T10:00:05Z",
        "msg-a",
        "end_turn",
        2,
        "thinking",
    ));
    // The end of a poll does not cut off a message that still ends in thinking.
    assert!(parser
        .flush_pending(time("2026-10-03T10:00:10Z"), false)
        .is_none());
    assert!(parser
        .flush_pending(time("2026-10-03T10:00:34Z"), false)
        .is_none());
    // The text arrives in a later poll and updates the same turn.
    parser.consume(&block_message(
        "2026-10-03T10:00:30Z",
        "msg-a",
        "end_turn",
        900,
        "text",
    ));
    let turn = parser
        .flush_pending(time("2026-10-03T10:00:31Z"), false)
        .unwrap();
    assert_eq!(turn.output_tokens, 900);
    assert_eq!(turn.completed_at, time("2026-10-03T10:00:30Z"));

    // Without text it closes once it has waited 30 s...
    let mut waiting = claude_parser();
    waiting.consume(&claude_user("2026-10-03T10:00:00Z", "human", json!("go")));
    waiting.consume(&block_message(
        "2026-10-03T10:00:05Z",
        "msg-a",
        "end_turn",
        400,
        "thinking",
    ));
    assert!(waiting
        .flush_pending(time("2026-10-03T10:00:34Z"), false)
        .is_none());
    let timed_out = waiting
        .flush_pending(time("2026-10-03T10:00:35Z"), false)
        .unwrap();
    assert_eq!(timed_out.output_tokens, 400);
    // ...and a complete (archive) read closes it at once.
    let mut archive = claude_parser();
    archive.consume(&claude_user("2026-10-03T10:00:00Z", "human", json!("go")));
    archive.consume(&block_message(
        "2026-10-03T10:00:05Z",
        "msg-a",
        "end_turn",
        400,
        "thinking",
    ));
    assert!(archive
        .flush_pending(time("2026-10-03T10:00:06Z"), true)
        .is_some());
}

#[test]
fn claude_replay_reader_closes_a_pending_terminal_turn_at_the_end_of_the_file() {
    let temp = TestDir::new();
    let path = temp.path().join("session.jsonl");
    fs::write(
        &path,
        jsonl(&[
            claude_user("2026-10-03T10:00:00Z", "human", json!("go")),
            block_message("2026-10-03T10:00:05Z", "msg-a", "end_turn", 300, "thinking"),
        ]),
    )
    .unwrap();
    let now = time("2026-10-03T10:00:06Z");
    // A live tail reader holds the thinking-last turn; a replay reader emits it.
    let mut live = crate::reader::IncrementalReader::recent_tail_claude(path.clone());
    let mut replay = crate::reader::IncrementalReader::beginning_claude(path);
    let (mut live_turns, mut replay_turns) = (Vec::new(), Vec::new());
    for _ in 0..4 {
        live_turns.extend(live.poll(1_048_576, now).unwrap());
        replay_turns.extend(replay.poll(1_048_576, now).unwrap());
    }
    assert!(live_turns.is_empty());
    assert_eq!(replay_turns.len(), 1);
    // The live reader gives up waiting after 30 s.
    assert_eq!(
        live.poll(1_048_576, now + Duration::seconds(30))
            .unwrap()
            .len(),
        1
    );
}

#[test]
fn grok_joins_zero_based_event_turns_to_one_based_usage_ledger_turns() {
    // Verbatim shape of a real Grok Build 1.0.x session: events number turns
    // from 0, the usage ledger from 1.
    let events = |session_id: &str| {
        let mut events = Vec::new();
        for (number, start, end) in [
            (0, "2026-09-28T09:50:38.177Z", "2026-09-28T09:52:30.218Z"),
            (1, "2026-09-28T09:52:42.306Z", "2026-09-28T09:53:25.953Z"),
        ] {
            events.push(grok_event(
                "turn_started",
                json!({
                    "ts":start,
                    "session_id":session_id,
                    "turn_number":number,
                    "session_relationship":"primary"
                }),
            ));
            // Real turn_ended events carry no schema_version.
            events.push(
                serde_json::to_vec(&json!({
                    "type":"turn_ended",
                    "ts":end,
                    "outcome":"completed"
                }))
                .unwrap(),
            );
        }
        events
    };
    let ledger = |session_id: &str, numbers: [u64; 2]| {
        json!({
            "sessionId":session_id,
            "updatedAt":"2026-09-28T09:53:25.968126+00:00",
            "session":{},
            "turns":[
                {
                    "turnNumber":numbers[0],
                    "endedAt":"2026-09-28T09:52:30.232828+00:00",
                    "outputTokens":4897,
                    "turnCount":1,
                    "modelUsage":{"grok-4.7-build":{"outputTokens":4897}}
                },
                {
                    "turnNumber":numbers[1],
                    "endedAt":"2026-09-28T09:53:25.968126+00:00",
                    "outputTokens":2505,
                    "turnCount":1,
                    "modelUsage":{"grok-4.7-build":{"outputTokens":2505}}
                }
            ]
        })
    };
    let poll_all = |root: &Path| {
        let mut monitor = GrokMonitor::new(root.to_path_buf());
        let mut found = Vec::new();
        for _ in 0..4 {
            found.extend(monitor.poll(time("2026-09-28T09:54:00Z")).unwrap());
        }
        found
    };

    let temp = TestDir::new();
    write_grok_session(
        temp.path(),
        "real",
        &events("real"),
        &ledger("real", [1, 2]),
    );
    let mut found = poll_all(temp.path());
    found.sort_by_key(|row| row.completed_at);
    assert_eq!(found.len(), 2);
    assert_eq!(
        found
            .iter()
            .map(|row| row.output_tokens)
            .collect::<Vec<_>>(),
        [4897, 2505]
    );
    assert!((found[0].duration_seconds - 112.041).abs() < 0.001);
    assert!((found[1].duration_seconds - 43.647).abs() < 0.001);
    assert!((found[0].turn_throughput_tps - 4897.0 / 112.041).abs() < 0.001);
    assert!((found[1].turn_throughput_tps - 2505.0 / 43.647).abs() < 0.001);
    assert!(found
        .iter()
        .all(|row| row.model.as_deref() == Some("grok-4.7-build")));

    // A ledger numbered like the events (the old assumption) matches no turn.
    let wrong = TestDir::new();
    write_grok_session(
        wrong.path(),
        "wrong",
        &events("wrong"),
        &ledger("wrong", [0, 1]),
    );
    assert!(poll_all(wrong.path()).is_empty());
}

/// Runs one Grok turn through the monitor. `backfilled` writes the finished session before
/// the first poll; otherwise the turn is appended after the monitor caught up with an empty log.
fn grok_effort_records(
    summary_at_start: Option<&str>,
    summary_at_emit: Option<&str>,
    backfilled: bool,
) -> Vec<crate::TurnMetric> {
    let temp = TestDir::new();
    let session = temp.path().join("effort");
    let write_summary = |effort: Option<&str>| {
        let path = session.join("summary.json");
        match effort {
            Some(value) => fs::write(
                path,
                serde_json::to_vec(&json!({
                    "reasoning_effort":value,
                    "current_model_id":"grok-4",
                    "context_window":256000
                }))
                .unwrap(),
            )
            .unwrap(),
            None => {
                let _ = fs::remove_file(path);
            }
        }
    };
    let events = grok_turn_events("effort", 0, "completed");
    let usage = grok_usage("effort", 0, 50);
    let now = time("2026-10-03T10:00:06Z");
    let mut monitor = GrokMonitor::new(temp.path().to_path_buf());
    let mut found = Vec::new();
    if backfilled {
        write_grok_session(temp.path(), "effort", &events, &usage);
        write_summary(summary_at_start);
        for _ in 0..2 {
            found.extend(monitor.poll(now).unwrap());
        }
    } else {
        write_grok_session(
            temp.path(),
            "effort",
            &[],
            &json!({"sessionId":"effort","updatedAt":"2026-10-03T10:00:05Z","turns":[]}),
        );
        write_summary(summary_at_start);
        for _ in 0..2 {
            assert!(monitor.poll(now).unwrap().is_empty());
        }
        fs::write(session.join("events.jsonl"), jsonl(&events[..1])).unwrap();
        monitor.note_changes(&changed(&[&session.join("events.jsonl")]));
        for _ in 0..2 {
            assert!(monitor.poll(now).unwrap().is_empty());
        }
        fs::write(session.join("events.jsonl"), jsonl(&events)).unwrap();
        fs::write(
            session.join("usage.json"),
            serde_json::to_vec(&usage).unwrap(),
        )
        .unwrap();
        monitor.note_changes(&changed(&[
            &session.join("events.jsonl"),
            &session.join("usage.json"),
        ]));
    }
    write_summary(summary_at_emit);
    monitor.note_changes(&changed(&[&session.join("summary.json")]));
    for _ in 0..3 {
        found.extend(monitor.poll(now).unwrap());
    }
    found
}

#[test]
fn grok_attributes_session_effort_only_when_observed_at_live_start_and_unchanged_at_emit() {
    let live = grok_effort_records(Some("high"), Some("high"), false);
    assert_eq!(live.len(), 1);
    assert_eq!(live[0].reasoning_effort.as_deref(), Some("high"));

    let changed = grok_effort_records(Some("high"), Some("low"), false);
    assert_eq!(changed.len(), 1);
    assert_eq!(changed[0].reasoning_effort, None);

    let backfilled = grok_effort_records(Some("high"), Some("high"), true);
    assert_eq!(backfilled.len(), 1);
    assert_eq!(backfilled[0].reasoning_effort, None);

    let missing = grok_effort_records(None, None, false);
    assert_eq!(missing.len(), 1);
    assert_eq!(missing[0].reasoning_effort, None);
}

fn with_parent(line: Vec<u8>, parent: &str) -> Vec<u8> {
    with_fields(line, json!({ "parentUuid": parent }))
}

#[test]
fn claude_response_starts_at_the_parent_record_of_its_first_assistant_record() {
    let mut parser = claude_parser();
    parser.consume(&claude_user("2026-10-03T10:00:00Z", "human", json!("go")));
    // An attachment written just before the request is the real start.
    parser.consume(&with_fields(
        serde_json::to_vec(&json!({
            "type": "attachment",
            "timestamp": "2026-10-03T10:00:08Z",
            "isSidechain": false,
            "userType": "external"
        }))
        .unwrap(),
        json!({ "uuid": "attachment-1" }),
    ));
    parser.consume(&with_parent(
        assistant("2026-10-03T10:00:14Z", "msg-a", "tool_use", 600),
        "attachment-1",
    ));
    // Later records of the same message keep the start.
    parser.consume(&with_parent(
        assistant("2026-10-03T10:00:18Z", "msg-a", "tool_use", 600),
        "assistant-msg-a",
    ));
    parser.consume(&tool_result("2026-10-03T10:00:20Z", "result"));
    parser.consume(&assistant("2026-10-03T10:00:30Z", "msg-b", "tool_use", 10));
    let live = parser.take_responses();
    assert_eq!(live.len(), 1);
    assert_eq!(live[0].duration_seconds, 10.0);
    assert_eq!(live[0].completed_at, time("2026-10-03T10:00:18Z"));
}

#[test]
fn claude_notification_written_mid_response_does_not_move_its_start() {
    let mut parser = claude_parser();
    parser.consume(&claude_user("2026-10-03T10:00:00Z", "human", json!("go")));
    parser.consume(&assistant("2026-10-03T10:00:04Z", "msg-a", "tool_use", 800));
    parser.consume(&user_with(
        "2026-10-03T10:00:06Z",
        "note",
        json!({"origin": {"kind": "task-notification"}}),
    ));
    parser.consume(&user_with(
        "2026-10-03T10:00:07Z",
        "meta",
        json!({"isMeta": true}),
    ));
    // The message continues after the notification and ends at its last record.
    parser.consume(&assistant(
        "2026-10-03T10:00:10Z",
        "msg-a",
        "tool_use",
        1_000,
    ));
    let turn = parser
        .consume_settled(&assistant("2026-10-03T10:00:30Z", "msg-b", "end_turn", 400))
        .unwrap();
    let live = parser.take_responses();
    // Start stays the human prompt (the latest user record before the first record: 10:00:00).
    assert_eq!(live[0].duration_seconds, 10.0);
    assert_eq!(live[0].output_tokens, 1_000);
    assert_eq!(turn.response_count, Some(2));
}

#[test]
fn claude_missing_or_later_parent_falls_back_to_the_latest_user_record() {
    let run = |parent: &str| {
        let mut parser = claude_parser();
        parser.consume(&claude_user("2026-10-03T10:00:00Z", "human", json!("go")));
        parser.consume(&tool_result("2026-10-03T10:00:03Z", "result"));
        parser.consume(&with_parent(
            assistant("2026-10-03T10:00:08Z", "msg-a", "tool_use", 500),
            parent,
        ));
        parser.flush_pending(time("2026-10-03T10:00:09Z"), true);
        parser.take_responses()
    };
    // Unknown parent: latest user record (10:00:03).
    assert_eq!(run("never-seen")[0].duration_seconds, 5.0);
    // A parent known but written after the response began cannot be its trigger.
    let mut parser = claude_parser();
    parser.consume(&claude_user("2026-10-03T10:00:00Z", "human", json!("go")));
    parser.consume(&with_fields(
        serde_json::to_vec(&json!({
            "type": "attachment",
            "timestamp": "2026-10-03T10:00:20Z",
            "isSidechain": false,
            "userType": "external"
        }))
        .unwrap(),
        json!({ "uuid": "late" }),
    ));
    parser.consume(&with_parent(
        assistant("2026-10-03T10:00:08Z", "msg-a", "tool_use", 500),
        "late",
    ));
    parser.flush_pending(time("2026-10-03T10:00:21Z"), true);
    assert_eq!(parser.take_responses()[0].duration_seconds, 8.0);
}

fn attachment(at: &str, uuid: &str, parent: &str, kind: &str) -> Vec<u8> {
    serde_json::to_vec(&json!({
        "type": "attachment",
        "timestamp": at,
        "isSidechain": false,
        "userType": "external",
        "uuid": uuid,
        "parentUuid": parent,
        "attachment": { "type": kind }
    }))
    .unwrap()
}

/// Real shape: Claude Code writes `deferred_tools_record` when the response arrives, and the
/// response's first assistant record names it as its parent.
fn claude_deferred_tools_sequence(deferred_parent: &str) -> Vec<Vec<u8>> {
    vec![
        claude_user("2026-10-03T08:39:40.000Z", "human", json!("go")),
        tool_result("2026-10-03T08:39:50.262Z", "result-1"),
        attachment(
            "2026-10-03T08:39:50.266Z",
            "reminder-1",
            "result-1",
            "total_tokens_reminder",
        ),
        attachment(
            "2026-10-03T08:39:54.257Z",
            "deferred-1",
            deferred_parent,
            "deferred_tools_record",
        ),
        with_parent(
            block_message(
                "2026-10-03T08:39:54.257Z",
                "msg-x",
                "end_turn",
                336,
                "thinking",
            ),
            "deferred-1",
        ),
        with_parent(
            block_message("2026-10-03T08:39:54.259Z", "msg-x", "end_turn", 336, "text"),
            "deferred-1",
        ),
    ]
}

/// Feeds records as a live read would and settles the pending terminal turn at the end.
fn claude_play(
    parser: &mut crate::claude_parser::ClaudeTranscriptParser,
    lines: Vec<Vec<u8>>,
) -> Option<TurnMetric> {
    let mut turn = None;
    for line in lines {
        turn = turn.or(parser.consume(&line));
    }
    turn.or_else(|| parser.flush_pending(DateTime::<Utc>::MAX_UTC, true))
}

#[test]
fn claude_deferred_tools_record_does_not_start_a_response_it_precedes() {
    let mut parser = claude_parser();
    let turn = claude_play(&mut parser, claude_deferred_tools_sequence("reminder-1")).unwrap();
    // The deferred_tools_record stands for its parent (50.266), not its own arrival time.
    let seconds = turn.response_duration_seconds.unwrap();
    assert!((seconds - 3.993).abs() < 1e-6, "{seconds}");
    assert_eq!(turn.response_output_tokens, Some(336));
    assert_eq!(turn.response_count, Some(1));
    let live = parser.take_responses();
    assert_eq!(live.len(), 1);
    assert!((live[0].duration_seconds - 3.993).abs() < 1e-6);
    assert!(live[0].speed() < 100.0);

    // Chains of bookkeeping attachments resolve to the first real record.
    let mut chained = claude_parser();
    let mut lines = claude_deferred_tools_sequence("reminder-1");
    lines.insert(
        4,
        attachment(
            "2026-10-03T08:39:54.257Z",
            "deferred-2",
            "deferred-1",
            "deferred_tools_record",
        ),
    );
    for line in lines.iter_mut().skip(5) {
        *line = with_parent(std::mem::take(line), "deferred-2");
    }
    claude_play(&mut chained, lines);
    let live = chained.take_responses();
    assert!((live[0].duration_seconds - 3.993).abs() < 1e-6);
}

#[test]
fn claude_deferred_tools_record_with_an_unknown_parent_falls_back_to_the_latest_user_record() {
    let mut parser = claude_parser();
    let turn = claude_play(&mut parser, claude_deferred_tools_sequence("never-seen"));
    // Not remembered at all, so the response starts at the tool result (50.262).
    let seconds = turn.unwrap().response_duration_seconds.unwrap();
    assert!((seconds - 3.997).abs() < 1e-6, "{seconds}");
    let live = parser.take_responses();
    assert!((live[0].duration_seconds - 3.997).abs() < 1e-6);
}

#[test]
fn claude_other_attachments_remain_request_triggers() {
    let mut parser = claude_parser();
    parser.consume(&claude_user("2026-10-03T10:00:00Z", "human", json!("go")));
    parser.consume(&attachment(
        "2026-10-03T10:00:08Z",
        "att-1",
        "human",
        "skill_listing",
    ));
    parser.consume(&with_parent(
        assistant("2026-10-03T10:00:14Z", "msg-a", "tool_use", 600),
        "att-1",
    ));
    parser.flush_pending(time("2026-10-03T10:00:15Z"), true);
    assert_eq!(parser.take_responses()[0].duration_seconds, 6.0);
}

#[test]
fn claude_turns_and_responses_above_the_speed_bound_are_not_emitted() {
    // 5,000 tokens in one second is a measurement error: no turn, no live response.
    let mut parser = claude_parser();
    parser.consume_settled(&claude_user("2026-10-03T10:00:00Z", "human", json!("go")));
    assert!(parser
        .consume_settled(&assistant(
            "2026-10-03T10:00:01Z",
            "fast",
            "end_turn",
            5_000
        ))
        .is_none());
    assert!(parser.take_responses().is_empty());

    // The same output over 3 s (1,667 tok/s) is kept.
    let mut plausible = claude_parser();
    plausible.consume_settled(&claude_user("2026-10-03T10:00:00Z", "human", json!("go")));
    let turn = plausible
        .consume_settled(&assistant("2026-10-03T10:00:03Z", "ok", "end_turn", 5_000))
        .unwrap();
    assert_eq!(turn.response_count, Some(1));

    // A fast response inside a slower turn is left out of the response fields and live list.
    let mut mixed = claude_parser();
    mixed.consume_settled(&claude_user("2026-10-03T10:00:00Z", "human", json!("go")));
    mixed.consume_settled(&assistant(
        "2026-10-03T10:00:09Z",
        "slow-tool",
        "tool_use",
        300,
    ));
    mixed.consume_settled(&tool_result("2026-10-03T10:00:10Z", "r"));
    let turn = mixed
        .consume_settled(&assistant(
            "2026-10-03T10:00:10.100Z",
            "fast",
            "end_turn",
            900,
        ))
        .unwrap();
    assert_eq!(turn.response_count, Some(1));
    assert_eq!(turn.response_output_tokens, Some(300));
    assert_eq!(mixed.take_responses().len(), 1);
}

#[test]
fn response_qualifies_rejects_implausibly_fast_responses() {
    use crate::response_qualifies;
    assert!(response_qualifies(2_000, 1.0));
    assert!(!response_qualifies(2_001, 1.0));
    assert!(!response_qualifies(336, 0.002));
    assert!(!response_qualifies(336, 0.0));
    assert!(!response_qualifies(336, f64::NAN));
}

#[test]
fn codex_turns_above_the_speed_bound_are_not_emitted() {
    let run = |tokens: i64| {
        let mut parser = crate::parser::CodexEventParser::new("file".into());
        let mut turn = None;
        for line in [
            codex_line(
                "session_meta",
                json!({"id": "session-1", "cli_version": "0.159.2", "source": "cli", "model_provider": "openai"}),
                "2026-10-03T10:00:00Z",
            ),
            codex_line(
                "event_msg",
                json!({"type": "task_started", "turn_id": "turn-1"}),
                "2026-10-03T10:00:00Z",
            ),
            codex_line(
                "turn_context",
                json!({"turn_id": "turn-1", "model": "gpt-test", "effort": "high"}),
                "2026-10-03T10:00:00.100Z",
            ),
            codex_item(json!({"type": "reasoning"}), "2026-10-03T10:00:00.500Z"),
            codex_usage("2026-10-03T10:00:01Z", "resp-1", tokens, tokens),
            codex_line(
                "event_msg",
                json!({"type": "task_complete", "turn_id": "turn-1", "duration_ms": 1000}),
                "2026-10-03T10:00:01.100Z",
            ),
        ] {
            turn = turn.or(parser.consume(&line));
        }
        (turn, parser.take_responses())
    };
    let (turn, live) = run(5_000);
    assert!(turn.is_none());
    assert!(live.is_empty());
    let (turn, live) = run(2_000);
    assert_eq!(turn.unwrap().output_tokens, 2_000);
    assert_eq!(live.len(), 1);
}

#[test]
fn claude_remembered_record_times_are_bounded_per_file() {
    let mut parser = claude_parser();
    parser.consume(&claude_user("2026-10-03T10:00:00Z", "first", json!("go")));
    parser.consume(&tool_result("2026-10-03T10:00:04Z", "second"));
    for index in 0..4_100 {
        parser.consume(&with_fields(
            serde_json::to_vec(&json!({
                "type": "attachment",
                "timestamp": "2026-10-03T10:00:01Z",
                "isSidechain": false,
                "userType": "external"
            }))
            .unwrap(),
            json!({ "uuid": format!("filler-{index}") }),
        ));
    }
    // The oldest record was forgotten, so its child falls back to the latest user record.
    parser.consume(&with_parent(
        assistant("2026-10-03T10:00:09Z", "msg-a", "tool_use", 500),
        "first",
    ));
    parser.flush_pending(time("2026-10-03T10:00:10Z"), true);
    assert_eq!(parser.take_responses()[0].duration_seconds, 5.0);

    // Within the bound the same parent is still resolved.
    let mut recent = claude_parser();
    recent.consume(&claude_user("2026-10-03T10:00:00Z", "first", json!("go")));
    recent.consume(&tool_result("2026-10-03T10:00:04Z", "second"));
    recent.consume(&with_parent(
        assistant("2026-10-03T10:00:09Z", "msg-a", "tool_use", 500),
        "first",
    ));
    recent.flush_pending(time("2026-10-03T10:00:10Z"), true);
    assert_eq!(recent.take_responses()[0].duration_seconds, 9.0);
}

// --- Grok Build response speed (whole-turn average over model calls) ----------------------------

/// Builds one primary Grok turn from `(milliseconds since 10:00:00Z, event type)` steps. The
/// session log, like a real one, carries phase and permission noise that must not matter.
fn grok_timed_events(session_id: &str, number: u64, steps: &[(i64, &str)]) -> Vec<Vec<u8>> {
    let base = time("2026-10-03T10:00:00Z");
    steps
        .iter()
        .map(|(offset, kind)| {
            let ts = (base + Duration::milliseconds(*offset))
                .to_rfc3339_opts(chrono::SecondsFormat::Millis, true);
            let mut event = json!({ "type": kind, "ts": ts });
            match *kind {
                "turn_started" => {
                    event["schema_version"] = json!("1.0");
                    event["session_id"] = json!(session_id);
                    event["turn_number"] = json!(number);
                    event["session_relationship"] = json!("primary");
                }
                "turn_ended" => event["outcome"] = json!("completed"),
                "tool_started" => event["tool_name"] = json!("run_command"),
                "loop_started" => event["loop_index"] = json!(0),
                _ => {}
            }
            serde_json::to_vec(&event).unwrap()
        })
        .collect()
}

/// A usage ledger row ending when the last step does; `model_calls` of `null` omits the field.
fn grok_timed_usage(
    session_id: &str,
    number: u64,
    output_tokens: i64,
    model_calls: Value,
    ended_ms: i64,
) -> Value {
    let ended = (time("2026-10-03T10:00:00Z") + Duration::milliseconds(ended_ms))
        .to_rfc3339_opts(chrono::SecondsFormat::Millis, true);
    let mut usage = grok_usage(session_id, number, output_tokens);
    usage["updatedAt"] = json!(ended);
    usage["turns"][0]["endedAt"] = json!(ended);
    if model_calls.is_null() {
        usage["turns"][0]
            .as_object_mut()
            .unwrap()
            .remove("modelCalls");
    } else {
        usage["turns"][0]["modelCalls"] = model_calls;
    }
    usage
}

/// Steps of a turn with one model call per window length (milliseconds). Every call but the last
/// ends at a tool, which runs for three seconds; the last one ends the turn.
fn grok_call_steps(windows_ms: &[i64]) -> Vec<(i64, &'static str)> {
    let mut steps = vec![(0, "turn_started")];
    let mut at = 1_000;
    for (index, window) in windows_ms.iter().enumerate() {
        steps.push((at, "loop_started"));
        steps.push((at + 10, "phase_changed"));
        steps.push((at + 400, "first_token"));
        steps.push((at + 500, "phase_changed"));
        if index + 1 == windows_ms.len() {
            steps.push((at + window, "turn_ended"));
        } else {
            steps.push((at + window, "tool_started"));
            steps.push((at + window + 100, "permission_requested"));
            steps.push((at + window + 1_100, "permission_resolved"));
            steps.push((at + window + 3_000, "tool_completed"));
            at += window + 3_000;
        }
    }
    steps
}

fn grok_turn_end_ms(steps: &[(i64, &str)]) -> i64 {
    steps.last().unwrap().0
}

fn grok_poll_all(root: &Path) -> Vec<TurnMetric> {
    let mut monitor = GrokMonitor::new(root.to_path_buf());
    let mut found = Vec::new();
    for _ in 0..4 {
        found.extend(monitor.poll(time("2026-10-03T10:30:00Z")).unwrap());
    }
    found
}

/// Runs a built turn through the monitor and returns the single emitted record.
fn grok_single_record(steps: &[(i64, &str)], output_tokens: i64, model_calls: Value) -> TurnMetric {
    let mut found = grok_records(steps, output_tokens, model_calls);
    assert_eq!(found.len(), 1, "the work turn itself is still recorded");
    found.remove(0)
}

/// Runs a built turn through the monitor and returns every emitted record.
fn grok_records(steps: &[(i64, &str)], output_tokens: i64, model_calls: Value) -> Vec<TurnMetric> {
    let temp = TestDir::new();
    write_grok_session(
        temp.path(),
        "timed",
        &grok_timed_events("timed", 0, steps),
        &grok_timed_usage(
            "timed",
            0,
            output_tokens,
            model_calls,
            grok_turn_end_ms(steps),
        ),
    );
    grok_poll_all(temp.path())
}

fn assert_no_grok_response_timing(record: &TurnMetric) {
    assert_eq!(record.response_output_tokens, None);
    assert_eq!(record.response_duration_seconds, None);
    assert_eq!(record.response_count, None);
}

#[test]
fn grok_real_shape_turn_reports_a_whole_turn_response_speed_over_all_model_calls() {
    // Shape and totals of a real Grok Build 1.0.46 turn: nine model calls whose generation
    // windows sum to 179.9 s (Grok's own apiDurationMs was 179.7 s) and 12,535 output tokens.
    let mut windows = vec![20_000; 9];
    windows[0] = 19_900;
    let steps = grok_call_steps(&windows);
    let record = grok_single_record(&steps, 12_535, json!(9));
    assert_eq!(record.parser_version, "grok-session-v2");
    assert_eq!(record.output_tokens, 12_535);
    assert_eq!(record.response_output_tokens, Some(12_535));
    assert_eq!(record.response_count, Some(9));
    assert!((record.response_duration_seconds.unwrap() - 179.9).abs() < 1e-6);
    let speed =
        record.response_output_tokens.unwrap() as f64 / record.response_duration_seconds.unwrap();
    assert!((speed - 69.68).abs() < 0.01);
    // Tool runs are excluded: the turn is longer than the generation windows.
    assert!(record.duration_seconds > record.response_duration_seconds.unwrap() + 20.0);

    // The shared sample carries the same fields under parser v2.
    let sample = crate::SharedSample::from_metric(&record, Uuid::new_v4()).unwrap();
    assert_eq!(sample.parser_version, "grok-session-v2");
    assert_eq!(sample.response_output_tokens, Some(12_535));
    assert_eq!(sample.response_count, Some(9));
    assert!((sample.response_duration_ms.unwrap() - 179_900.0).abs() < 1e-3);
}

#[test]
fn grok_final_window_is_closed_by_turn_ended_and_a_new_loop_closes_the_previous_window() {
    // One call, no tool: the window runs to the turn's end.
    let single = grok_call_steps(&[30_000]);
    let record = grok_single_record(&single, 3_000, json!(1));
    assert_eq!(record.response_count, Some(1));
    assert!((record.response_duration_seconds.unwrap() - 30.0).abs() < 1e-6);

    // Two calls without a tool between them: the second loop closes the first window.
    let steps = vec![
        (0, "turn_started"),
        (1_000, "loop_started"),
        (11_000, "loop_started"),
        (31_000, "turn_ended"),
    ];
    let record = grok_single_record(&steps, 6_000, json!(2));
    assert_eq!(record.response_count, Some(2));
    assert!((record.response_duration_seconds.unwrap() - 30.0).abs() < 1e-6);
}

#[test]
fn grok_repeated_tool_started_events_in_one_call_do_not_extend_the_window() {
    let steps = vec![
        (0, "turn_started"),
        (1_000, "loop_started"),
        (11_000, "tool_started"),
        (11_500, "tool_started"),
        (12_000, "tool_started"),
        (20_000, "tool_completed"),
        (21_000, "loop_started"),
        (31_000, "turn_ended"),
    ];
    let record = grok_single_record(&steps, 4_000, json!(2));
    assert_eq!(record.response_count, Some(2));
    assert!((record.response_duration_seconds.unwrap() - 20.0).abs() < 1e-6);
}

#[test]
fn grok_nested_agents_keep_the_work_turn_but_have_no_response_timing() {
    let session = "nested";
    let mut events = grok_timed_events(
        session,
        0,
        &[
            (0, "turn_started"),
            (1_000, "loop_started"),
            (11_000, "tool_started"),
        ],
    );
    events.push(grok_event(
        "turn_started",
        json!({
            "ts":"2026-10-03T10:00:12Z",
            "session_id":session,
            "turn_number":1,
            "session_relationship":"subagent"
        }),
    ));
    // The nested agent's own model calls are not the primary turn's windows.
    events.extend(grok_timed_events(
        session,
        0,
        &[(13_000, "loop_started"), (23_000, "tool_started")],
    ));
    events.extend(grok_timed_events(session, 0, &[(25_000, "turn_ended")]));
    events.extend(grok_timed_events(
        session,
        0,
        &[(26_000, "loop_started"), (36_000, "turn_ended")],
    ));
    let temp = TestDir::new();
    write_grok_session(
        temp.path(),
        session,
        &events,
        &grok_timed_usage(session, 0, 4_000, json!(2), 36_000),
    );
    let found = grok_poll_all(temp.path());
    assert_eq!(found.len(), 1, "the usage still includes the nested output");
    assert_eq!(found[0].output_tokens, 4_000);
    assert_no_grok_response_timing(&found[0]);
}

#[test]
fn grok_windows_longer_than_the_response_limit_have_no_response_timing() {
    let ten_minutes = grok_call_steps(&[600_000, 10_000]);
    let record = grok_single_record(&ten_minutes, 4_000, json!(2));
    assert_eq!(record.response_count, Some(2), "exactly 600 s still counts");

    let too_long = grok_call_steps(&[600_001, 10_000]);
    let record = grok_single_record(&too_long, 4_000, json!(2));
    assert_eq!(record.output_tokens, 4_000);
    assert_no_grok_response_timing(&record);
}

#[test]
fn grok_model_call_count_must_match_the_usage_ledger_when_present() {
    let steps = grok_call_steps(&[20_000, 20_000, 20_000]);
    assert_no_grok_response_timing(&grok_single_record(&steps, 3_000, json!(4)));
    assert_no_grok_response_timing(&grok_single_record(&steps, 3_000, json!(2)));
    assert_no_grok_response_timing(&grok_single_record(&steps, 3_000, json!("3")));
    assert_no_grok_response_timing(&grok_single_record(&steps, 3_000, json!(-3)));
    assert_eq!(
        grok_single_record(&steps, 3_000, json!(3)).response_count,
        Some(3)
    );
    // A ledger row without modelCalls accepts the window count.
    assert_eq!(
        grok_single_record(&steps, 3_000, Value::Null).response_count,
        Some(3)
    );
}

#[test]
fn grok_needs_at_least_the_response_minimum_output_tokens_per_model_call_on_average() {
    let steps = grok_call_steps(&[20_000; 9]);
    assert_no_grok_response_timing(&grok_single_record(&steps, 1_799, json!(9)));
    let exact = grok_single_record(&steps, 1_800, json!(9));
    assert_eq!(exact.response_output_tokens, Some(1_800));
    assert_eq!(exact.response_count, Some(9));
}

#[test]
fn grok_implausibly_fast_or_unwindowed_turns_have_no_response_timing() {
    // 60,000 tokens in a 21 s turn is 2,857 tok/s: a measurement error, so no record at all.
    let steps = grok_call_steps(&[20_000]);
    assert!(grok_records(&steps, 60_000, json!(1)).is_empty());
    assert_eq!(
        grok_single_record(&steps, 40_000, json!(1)).response_count,
        Some(1)
    );

    // 30,000 tokens in 10 s of generation is 3,000 tok/s, above the shared limit, inside a 42 s
    // turn (714 tok/s): the turn is recorded without response timing.
    let slow_tool = vec![
        (0, "turn_started"),
        (1_000, "loop_started"),
        (11_000, "tool_started"),
        (41_000, "tool_completed"),
        (42_000, "turn_ended"),
    ];
    assert_no_grok_response_timing(&grok_single_record(&slow_tool, 30_000, json!(1)));

    // No loop events: nothing to time.
    let bare = vec![(0, "turn_started"), (20_000, "turn_ended")];
    assert_no_grok_response_timing(&grok_single_record(&bare, 3_000, json!(1)));

    // A window with no extent is not a window.
    let instant = vec![
        (0, "turn_started"),
        (1_000, "loop_started"),
        (1_000, "tool_started"),
        (2_000, "loop_started"),
        (22_000, "turn_ended"),
    ];
    assert_no_grok_response_timing(&grok_single_record(&instant, 3_000, json!(2)));
}

#[test]
fn grok_parser_v1_history_is_not_shared_by_this_version() {
    let steps = grok_call_steps(&[20_000]);
    let mut record = grok_single_record(&steps, 2_000, json!(1));
    assert!(crate::SharedSample::from_metric(&record, Uuid::new_v4()).is_some());
    record.parser_version = "grok-session-v1".into();
    assert!(crate::SharedSample::from_metric(&record, Uuid::new_v4()).is_none());
    // It still decodes and displays locally.
    let decoded: TurnMetric =
        serde_json::from_value(serde_json::to_value(&record).unwrap()).unwrap();
    assert_eq!(decoded.parser_version, "grok-session-v1");
}

// --- Delegated output attribution (0.1.16) -----------------------------------------------------

#[test]
fn grok_turns_are_final_at_emission_with_zero_delegated_output() {
    let steps = grok_call_steps(&[20_000]);
    let record = grok_single_record(&steps, 2_000, json!(1));
    // Grok's ledger output already includes nested agent output.
    assert_eq!(record.delegated_output_tokens, Some(0));
    let sample = crate::SharedSample::from_metric(&record, Uuid::new_v4()).unwrap();
    assert_eq!(sample.delegated_output_tokens, Some(0));
}

#[test]
fn delegated_output_is_validated_and_null_for_every_source_kind_but_primary() {
    let now = time("2026-10-03T10:00:00Z");
    let share = |turn: &TurnMetric| crate::SharedSample::from_metric(turn, Uuid::new_v4());
    let mut primary = metric("primary", now);

    primary.delegated_output_tokens = Some(0);
    assert_eq!(share(&primary).unwrap().delegated_output_tokens, Some(0));
    primary.delegated_output_tokens = Some(100_000_000);
    assert_eq!(
        serde_json::to_value(share(&primary).unwrap()).unwrap()["delegatedOutputTokens"],
        100_000_000
    );
    // Out of range or not yet final: no sample at all.
    for invalid in [Some(100_000_001), Some(-1), None] {
        primary.delegated_output_tokens = invalid;
        assert!(share(&primary).is_none(), "{invalid:?}");
    }

    // Subagent turns carry an explicit null, whatever the record holds.
    let mut subagent = metric("subagent", now);
    subagent.client = CLAUDE_CLIENT.into();
    subagent.parser_version = CLAUDE_PARSER_VERSION.into();
    subagent.metric_version = CLAUDE_SUBAGENT_METRIC_VERSION.into();
    subagent.source_kind = Some("subagent".into());
    for held in [None, Some(5)] {
        subagent.delegated_output_tokens = held;
        let json = serde_json::to_value(share(&subagent).unwrap()).unwrap();
        assert!(json
            .as_object()
            .unwrap()
            .contains_key("delegatedOutputTokens"));
        assert!(json["delegatedOutputTokens"].is_null());
    }
}

#[test]
fn sharing_queue_waits_for_final_primary_turns_and_shares_each_turn_once() {
    let now = time("2026-10-03T10:00:00Z");
    let mut queue = SharingQueue::new();
    queue.enable(now);
    let at = now + Duration::seconds(10);
    let mut provisional = metric("turn", at);
    provisional.delegated_output_tokens = None;
    let settled = provisional.with_delegated_output_tokens(40);

    // A primary turn whose attribution is not final is held back and not remembered as seen.
    queue.enqueue(&[provisional.clone()], at + Duration::seconds(1));
    assert!(queue.is_empty());
    // A subagent turn is shared as today, without waiting.
    let mut subagent = provisional.clone();
    subagent.id = "subagent".into();
    subagent.source_kind = Some("subagent".into());
    subagent.client = CLAUDE_CLIENT.into();
    subagent.parser_version = CLAUDE_PARSER_VERSION.into();
    subagent.metric_version = CLAUDE_SUBAGENT_METRIC_VERSION.into();
    queue.enqueue(&[subagent], at + Duration::seconds(1));
    assert_eq!(queue.len(), 1);

    // The finalized re-emission of the same id is shared, once.
    queue.enqueue(std::slice::from_ref(&settled), at + Duration::seconds(40));
    assert_eq!(queue.len(), 2);
    queue.enqueue(
        &[provisional.clone(), settled.clone()],
        at + Duration::seconds(41),
    );
    assert_eq!(queue.len(), 2);
    let batch = queue.batch(at + Duration::minutes(12));
    let delegated: Vec<Option<i64>> = batch
        .iter()
        .map(|sample| sample.delegated_output_tokens)
        .collect();
    assert_eq!(delegated, vec![None, Some(40)]);
    // Acknowledged samples are not shared again by a later re-emission.
    queue.ack(
        &batch
            .iter()
            .map(|sample| sample.sample_id)
            .collect::<Vec<_>>(),
    );
    queue.enqueue(&[settled], at + Duration::seconds(50));
    assert!(queue.is_empty());

    // A final turn that completed before sharing was enabled is still never backfilled.
    queue.disable();
    queue.enable(at + Duration::seconds(100));
    queue.enqueue(
        &[provisional.with_delegated_output_tokens(1)],
        at + Duration::seconds(101),
    );
    assert!(queue.is_empty());
}

// Claude Code: subagent transcripts are joined to the primary turn of the same session.

const DELEGATION_SESSION: &str = "session-delegation";

struct ClaudeDelegation {
    _temp: TestDir,
    project: PathBuf,
    monitor: SourceMonitor,
    latest: std::collections::HashMap<String, TurnMetric>,
}

impl ClaudeDelegation {
    fn new() -> Self {
        let temp = TestDir::new();
        let codex = temp.path().join("codex");
        let claude = temp.path().join("claude-projects");
        let grok = temp.path().join("grok-sessions");
        let project = claude.join("project-a");
        for directory in [&codex, &grok, &project] {
            fs::create_dir_all(directory).unwrap();
        }
        Self {
            monitor: SourceMonitor::new(
                codex,
                claude,
                grok,
                temp.path().join("gemini"),
                temp.path().join("opencode"),
            ),
            project,
            latest: Default::default(),
            _temp: temp,
        }
    }

    fn primary(&self, start: &str, end: &str, tokens: i64) {
        let with_session = |line| with_fields(line, json!({"sessionId": DELEGATION_SESSION}));
        fs::write(
            self.project.join(format!("{DELEGATION_SESSION}.jsonl")),
            jsonl(&[
                with_session(claude_user(start, "main-user", json!("synthetic"))),
                with_session(assistant(end, "main-call", "end_turn", tokens)),
            ]),
        )
        .unwrap();
    }

    fn subagent_path(&self, session: &str, agent: &str) -> PathBuf {
        let directory = self.project.join(session).join("subagents");
        fs::create_dir_all(&directory).unwrap();
        directory.join(format!("agent-{agent}.jsonl"))
    }

    fn write(&self, session: &str, agent: &str, lines: &[Vec<u8>]) {
        fs::write(self.subagent_path(session, agent), jsonl(lines)).unwrap();
    }

    fn set_modified(&self, session: &str, agent: &str, modified: &str) {
        fs::OpenOptions::new()
            .write(true)
            .open(self.subagent_path(session, agent))
            .unwrap()
            .set_modified(SystemTime::from(time(modified)))
            .unwrap();
    }

    /// Appends and reports the write, as the host's folder watcher would.
    fn append(&mut self, session: &str, agent: &str, lines: &[Vec<u8>]) {
        let path = self.subagent_path(session, agent);
        let mut file = fs::OpenOptions::new().append(true).open(&path).unwrap();
        file.write_all(&jsonl(lines)).unwrap();
        self.monitor.note_changes(&changed(&[&path]));
    }

    /// Polls until the monitors are idle at `now`; the latest version of each id wins, as in history.
    fn poll(&mut self, now: &str) {
        let now = time(now);
        for _ in 0..6 {
            for record in self.monitor.poll(now).unwrap() {
                self.latest.insert(record.id.clone(), record);
            }
        }
    }

    fn primary_turn(&self) -> &TurnMetric {
        let mut turns = self
            .latest
            .values()
            .filter(|record| record.source_kind.as_deref() == Some("primary"));
        let turn = turns.next().expect("a primary turn was emitted");
        assert!(turns.next().is_none());
        turn
    }

    fn subagent_turns(&self) -> Vec<&TurnMetric> {
        self.latest
            .values()
            .filter(|record| record.source_kind.as_deref() == Some("subagent"))
            .collect()
    }
}

/// A finished subagent turn: one prompt and one terminal response of `tokens` output tokens.
fn finished_subagent(
    session: &str,
    agent: &str,
    start: &str,
    end: &str,
    tokens: i64,
) -> Vec<Vec<u8>> {
    vec![
        as_subagent(
            claude_user(start, &format!("{agent}-user"), json!("synthetic")),
            session,
            agent,
        ),
        as_subagent(
            assistant(end, &format!("{agent}-call"), "end_turn", tokens),
            session,
            agent,
        ),
    ]
}

/// A subagent turn that has started and produced a tool call but not ended.
fn running_subagent(
    session: &str,
    agent: &str,
    start: &str,
    at: &str,
    tokens: i64,
) -> Vec<Vec<u8>> {
    vec![
        as_subagent(
            claude_user(start, &format!("{agent}-user"), json!("synthetic")),
            session,
            agent,
        ),
        as_subagent(
            assistant(at, &format!("{agent}-step"), "tool_use", tokens),
            session,
            agent,
        ),
    ]
}

#[test]
fn claude_subagent_that_ends_before_the_parent_is_counted_after_the_settle_time() {
    let mut fixture = ClaudeDelegation::new();
    fixture.primary("2026-10-03T10:00:00Z", "2026-10-03T10:01:00Z", 500);
    fixture.write(
        DELEGATION_SESSION,
        "sync",
        &finished_subagent(
            DELEGATION_SESSION,
            "sync",
            "2026-10-03T10:00:10Z",
            "2026-10-03T10:00:40Z",
            300,
        ),
    );

    // Emitted at once so speeds update, without waiting for attribution.
    fixture.poll("2026-10-03T10:01:10Z");
    assert_eq!(fixture.primary_turn().output_tokens, 500);
    assert_eq!(fixture.primary_turn().delegated_output_tokens, None);
    let provisional_id = fixture.primary_turn().id.clone();

    // 30 s after the parent ended the same record is re-emitted with the sum.
    fixture.poll("2026-10-03T10:01:29Z");
    assert_eq!(fixture.primary_turn().delegated_output_tokens, None);
    fixture.poll("2026-10-03T10:01:30Z");
    let turn = fixture.primary_turn();
    assert_eq!(turn.id, provisional_id);
    assert_eq!(turn.delegated_output_tokens, Some(300));
    assert_eq!(turn.output_tokens, 500);
    // Subagent records are still recorded as before and never attributed.
    let subagents = fixture.subagent_turns();
    assert_eq!(subagents.len(), 1);
    assert_eq!(subagents[0].output_tokens, 300);
    assert_eq!(subagents[0].delegated_output_tokens, None);
}

#[test]
fn claude_turn_without_subagents_settles_to_zero() {
    let mut fixture = ClaudeDelegation::new();
    fixture.primary("2026-10-03T10:00:00Z", "2026-10-03T10:01:00Z", 500);
    fixture.poll("2026-10-03T10:00:50Z");
    assert_eq!(fixture.primary_turn().delegated_output_tokens, None);
    fixture.poll("2026-10-03T10:02:00Z");
    assert_eq!(fixture.primary_turn().delegated_output_tokens, Some(0));
}

#[test]
fn claude_background_subagent_is_awaited_and_counted_when_it_finishes_after_the_parent() {
    let mut fixture = ClaudeDelegation::new();
    fixture.primary("2026-10-03T10:00:00Z", "2026-10-03T10:01:00Z", 500);
    fixture.write(
        DELEGATION_SESSION,
        "background",
        &running_subagent(
            DELEGATION_SESSION,
            "background",
            "2026-10-03T10:00:30Z",
            "2026-10-03T10:00:31Z",
            100,
        ),
    );
    // The parent has been over for 30 s but its background agent still runs: not final.
    fixture.poll("2026-10-03T10:01:45Z");
    assert_eq!(fixture.primary_turn().delegated_output_tokens, None);
    fixture.poll("2026-10-03T10:20:00Z");
    assert_eq!(fixture.primary_turn().delegated_output_tokens, None);

    // It finishes long after the parent: the record is re-emitted with the sum.
    fixture.append(
        DELEGATION_SESSION,
        "background",
        &[as_subagent(
            assistant("2026-10-03T10:21:00Z", "background-end", "end_turn", 200),
            DELEGATION_SESSION,
            "background",
        )],
    );
    fixture.poll("2026-10-03T10:21:30Z");
    assert_eq!(fixture.primary_turn().delegated_output_tokens, Some(300));
    assert_eq!(fixture.subagent_turns()[0].output_tokens, 300);
}

#[test]
fn claude_discarded_subagent_work_is_not_counted_and_does_not_block_the_turn() {
    let mut fixture = ClaudeDelegation::new();
    fixture.primary("2026-10-03T10:00:00Z", "2026-10-03T10:01:00Z", 500);
    let mut interrupted = running_subagent(
        DELEGATION_SESSION,
        "stopped",
        "2026-10-03T10:00:10Z",
        "2026-10-03T10:00:12Z",
        5_000,
    );
    interrupted.push(as_subagent(
        claude_user(
            "2026-10-03T10:00:20Z",
            "stopped-interrupt",
            json!("[Request interrupted by user]"),
        ),
        DELEGATION_SESSION,
        "stopped",
    ));
    fixture.write(DELEGATION_SESSION, "stopped", &interrupted);
    fixture.write(
        DELEGATION_SESSION,
        "done",
        &finished_subagent(
            DELEGATION_SESSION,
            "done",
            "2026-10-03T10:00:30Z",
            "2026-10-03T10:00:50Z",
            200,
        ),
    );
    fixture.poll("2026-10-03T10:02:00Z");
    assert_eq!(fixture.primary_turn().delegated_output_tokens, Some(200));
}

#[test]
fn claude_work_still_open_after_the_maximum_wait_is_ignored() {
    let mut fixture = ClaudeDelegation::new();
    fixture.primary("2026-10-03T10:00:00Z", "2026-10-03T10:01:00Z", 500);
    fixture.write(
        DELEGATION_SESSION,
        "stuck",
        &running_subagent(
            DELEGATION_SESSION,
            "stuck",
            "2026-10-03T10:00:30Z",
            "2026-10-03T10:00:31Z",
            700,
        ),
    );
    fixture.write(
        DELEGATION_SESSION,
        "done",
        &finished_subagent(
            DELEGATION_SESSION,
            "done",
            "2026-10-03T10:00:10Z",
            "2026-10-03T10:00:20Z",
            100,
        ),
    );
    fixture.poll("2026-10-03T10:30:59Z");
    assert_eq!(fixture.primary_turn().delegated_output_tokens, None);
    // 30 minutes after the parent ended the open work no longer holds the turn back.
    fixture.poll("2026-10-03T10:31:00Z");
    assert_eq!(fixture.primary_turn().delegated_output_tokens, Some(100));
}

#[test]
fn claude_work_outside_the_turn_window_or_session_is_not_counted() {
    let mut fixture = ClaudeDelegation::new();
    fixture.primary("2026-10-03T10:00:00Z", "2026-10-03T10:01:00Z", 500);
    let add = |agent: &str, session: &str, start: &str, end: &str, tokens: i64| {
        fixture.write(
            session,
            agent,
            &finished_subagent(session, agent, start, end, tokens),
        );
    };
    add(
        "before",
        DELEGATION_SESSION,
        "2026-10-03T09:59:00Z",
        "2026-10-03T10:00:30Z",
        500,
    );
    add(
        "after",
        DELEGATION_SESSION,
        "2026-10-03T10:01:01Z",
        "2026-10-03T10:01:20Z",
        400,
    );
    add(
        "other",
        "session-other",
        "2026-10-03T10:00:20Z",
        "2026-10-03T10:00:40Z",
        900,
    );
    // Both window edges are inclusive.
    add(
        "first",
        DELEGATION_SESSION,
        "2026-10-03T10:00:00Z",
        "2026-10-03T10:00:05Z",
        11,
    );
    add(
        "last",
        DELEGATION_SESSION,
        "2026-10-03T10:01:00Z",
        "2026-10-03T10:01:10Z",
        13,
    );
    fixture.poll("2026-10-03T10:03:00Z");
    assert_eq!(fixture.primary_turn().delegated_output_tokens, Some(24));
}

#[test]
fn claude_turns_are_not_final_while_subagent_history_is_still_being_read() {
    let mut fixture = ClaudeDelegation::new();
    fixture.primary("2026-10-03T10:00:00Z", "2026-10-03T10:01:00Z", 500);
    // The finished subagent turn comes first; filler pushes the file past the replay threshold.
    let mut lines = finished_subagent(
        DELEGATION_SESSION,
        "large",
        "2026-10-03T10:00:10Z",
        "2026-10-03T10:00:40Z",
        300,
    );
    let filler =
        serde_json::to_vec(&json!({"type": "summary", "padding": "x".repeat(8_000)})).unwrap();
    lines.extend(std::iter::repeat_n(filler, 100));
    fixture.write(DELEGATION_SESSION, "large", &lines);
    // Modified while the turn ran, so the unread history can hold its work.
    fixture.set_modified(DELEGATION_SESSION, "large", "2026-10-03T10:00:50Z");

    // Far past the settle time, but the subagent file is still being replayed.
    let now = time("2026-10-03T11:00:00Z");
    let mut polls = 0;
    loop {
        polls += 1;
        for record in fixture.monitor.poll(now).unwrap() {
            fixture.latest.insert(record.id.clone(), record);
        }
        let primary = fixture
            .latest
            .values()
            .find(|record| record.source_kind.as_deref() == Some("primary"));
        if primary.is_some_and(|turn| turn.delegated_output_tokens.is_some()) {
            break;
        }
        assert!(polls < 80, "the turn never became final");
    }
    assert!(
        polls > 3,
        "finalized after {polls} polls, before the replay was done"
    );
    assert_eq!(fixture.primary_turn().delegated_output_tokens, Some(300));
}

#[test]
fn claude_turn_is_final_while_unrelated_older_subagent_history_is_still_replayed() {
    let mut fixture = ClaudeDelegation::new();
    fixture.primary("2026-10-03T10:00:00Z", "2026-10-03T10:01:00Z", 500);
    fixture.write(
        DELEGATION_SESSION,
        "mine",
        &finished_subagent(
            DELEGATION_SESSION,
            "mine",
            "2026-10-03T10:00:10Z",
            "2026-10-03T10:00:40Z",
            300,
        ),
    );
    fixture.set_modified(DELEGATION_SESSION, "mine", "2026-10-03T10:00:50Z");
    // A large older session: last modified before the turn started, replay far from done.
    let mut history = finished_subagent(
        "session-older",
        "history",
        "2026-10-03T08:00:10Z",
        "2026-10-03T08:00:40Z",
        900,
    );
    let filler =
        serde_json::to_vec(&json!({"type": "summary", "padding": "x".repeat(8_000)})).unwrap();
    history.extend(std::iter::repeat_n(filler, 130));
    fixture.write("session-older", "history", &history);
    fixture.set_modified("session-older", "history", "2026-10-03T09:00:00Z");

    fixture.poll("2026-10-03T10:02:00Z");
    assert!(
        fixture.monitor.bytes_read_last_poll() > 0,
        "the older history was already fully read"
    );
    assert_eq!(fixture.primary_turn().delegated_output_tokens, Some(300));
}

// The attribution asks the backlog per pending turn with that turn's start.

fn backlog_file(modified_at: DateTime<Utc>) -> crate::delegation::DelegationFileBacklog {
    crate::delegation::DelegationFileBacklog {
        modified_at,
        live_pending: false,
        archive_pending: false,
        live_started_at: None,
        skipped_through: None,
    }
}

#[test]
fn backlog_predicate_ignores_files_modified_before_the_work_could_start() {
    let start = time("2026-10-03T10:00:00Z");
    // A pending live reader or archive on a file that is too old never blocks.
    let mut file = backlog_file(start - Duration::hours(1));
    file.live_pending = true;
    file.archive_pending = true;
    file.live_started_at = Some(start + Duration::minutes(5));
    assert!(!file.blocks(start));

    // The tolerance edge is inclusive: exactly two seconds before the start still blocks.
    let mut live = backlog_file(start - Duration::seconds(2));
    live.live_pending = true;
    assert!(live.blocks(start));
    live.modified_at = start - Duration::milliseconds(2_001);
    assert!(!live.blocks(start));
    // A file that is fully read blocks nothing, however recent.
    assert!(!backlog_file(start + Duration::minutes(1)).blocks(start));
}

#[test]
fn backlog_predicate_blocks_on_an_archive_only_when_the_live_tail_started_after_the_work() {
    let start = time("2026-10-03T10:00:00Z");
    let mut file = backlog_file(start + Duration::minutes(1));
    file.archive_pending = true;

    // The tail was positioned after the turn began: replayed content can hold its work.
    file.live_started_at = Some(start + Duration::seconds(5));
    assert!(file.blocks(start));
    file.live_started_at = Some(start - Duration::seconds(2));
    assert!(file.blocks(start));
    // The tail already covers everything from before the turn: the archive holds none of it.
    file.live_started_at = Some(start - Duration::milliseconds(2_001));
    assert!(!file.blocks(start));
    // A reader that is not positioned yet cannot rule it out.
    file.live_started_at = None;
    assert!(file.blocks(start));
}

#[test]
fn turns_are_final_after_the_settle_time_unless_a_relevant_file_has_unread_content() {
    use crate::delegation::{root_session_key, DelegationEvent, DelegationTracker};

    let started = time("2026-10-03T10:00:00Z");
    let completed = time("2026-10-03T10:01:00Z");
    let mut turn = metric("turn", completed);
    turn.delegated_output_tokens = None;
    let events = vec![DelegationEvent::Turn {
        turn_id: "turn".into(),
        root_session: root_session_key("codex", "root"),
        started_at: started,
    }];
    let settled = completed + Duration::seconds(30);
    let blocked = |files: &[crate::delegation::DelegationFileBacklog]| {
        let files = files.to_vec();
        move |work_start: DateTime<Utc>| files.iter().any(|file| file.blocks(work_start))
    };
    let final_count = |records: &[TurnMetric]| {
        records
            .iter()
            .filter(|record| record.delegated_output_tokens.is_some())
            .count()
    };

    // An unrelated large file last modified before the turn still has an archive reader.
    let mut unrelated = backlog_file(started - Duration::hours(2));
    unrelated.archive_pending = true;
    unrelated.live_started_at = Some(started + Duration::seconds(10));
    // A file modified during the turn whose live reader is not caught up, or that holds an
    // unread modification (the monitor reports both as a pending live reader).
    let mut related = backlog_file(started + Duration::seconds(30));
    related.live_pending = true;

    let mut tracker = DelegationTracker::new();
    let first = tracker.apply(
        vec![turn],
        events,
        completed + Duration::seconds(5),
        blocked(&[unrelated]),
        |_| false,
    );
    assert_eq!(final_count(&first), 0);
    // Not before the settle time, even without a relevant backlog.
    let early = tracker.apply(
        vec![],
        vec![],
        settled - Duration::seconds(1),
        blocked(&[unrelated]),
        |_| false,
    );
    assert_eq!(final_count(&early), 0);
    // Blocked by the relevant file, whatever else is going on.
    let held = tracker.apply(
        vec![],
        vec![],
        settled,
        blocked(&[unrelated, related]),
        |_| false,
    );
    assert_eq!(final_count(&held), 0);
    // Final once that file has been read, with the unrelated archive still pending.
    let done = tracker.apply(vec![], vec![], settled, blocked(&[unrelated]), |_| false);
    assert_eq!(final_count(&done), 1);
    assert_eq!(done[0].delegated_output_tokens, Some(0));
}

// Codex: child sessions spawned with `thread_spawn` are delegated work of their root session.

fn codex_turn_lines(meta: Value, turn: &str, start: &str, end: &str, tokens: i64) -> Vec<Vec<u8>> {
    let usage_at = end.replace("Z", ".000Z");
    vec![
        codex_line("session_meta", meta, start),
        codex_line(
            "event_msg",
            json!({"type": "task_started", "turn_id": turn, "started_at": start}),
            start,
        ),
        codex_line(
            "turn_context",
            json!({"turn_id": turn, "model": "gpt-test", "effort": "high"}),
            start,
        ),
        codex_item(json!({"type": "message", "role": "user"}), start),
        codex_item(json!({"type": "reasoning"}), start),
        codex_line(
            "token_usage_record",
            json!({
                "turn_id": turn,
                "response_id": format!("response-{turn}"),
                "usage": {"output_tokens": tokens},
                "turn_token_usage": {"output_tokens": tokens}
            }),
            &usage_at,
        ),
        codex_line(
            "event_msg",
            json!({"type": "task_complete", "turn_id": turn, "started_at": start, "completed_at": end}),
            end,
        ),
    ]
}

fn thread_spawn_meta(id: &str, session_id: Option<&str>, parent: &str) -> Value {
    let mut meta = json!({
        "id": id,
        "parent_thread_id": parent,
        "source": {"subagent": {"thread_spawn": {"parent_thread_id": parent, "depth": 1}}},
        "model_provider": "openai"
    });
    if let Some(session_id) = session_id {
        meta["session_id"] = session_id.into();
    }
    meta
}

fn primary_codex_meta(id: &str) -> Value {
    json!({"id": id, "source": "cli", "model_provider": "openai", "cli_version": "0.159.2"})
}

#[test]
fn codex_thread_spawn_children_attribute_to_their_root_session_turn() {
    let temp = TestDir::new();
    let sessions = temp.path().join("sessions");
    fs::create_dir_all(sessions.join("2026/10/03")).unwrap();
    let write = |name: &str, lines: Vec<Vec<u8>>| {
        fs::write(sessions.join("2026/10/03").join(name), jsonl(&lines)).unwrap();
    };
    write(
        "rollout-root.jsonl",
        codex_turn_lines(
            primary_codex_meta("root-1"),
            "root-turn",
            "2026-10-03T10:00:00Z",
            "2026-10-03T10:02:00Z",
            500,
        ),
    );
    // A child names its root through `session_id`; a nested child names the root as well.
    write(
        "rollout-child.jsonl",
        codex_turn_lines(
            thread_spawn_meta("child-1", Some("root-1"), "root-1"),
            "child-turn",
            "2026-10-03T10:00:20Z",
            "2026-10-03T10:00:50Z",
            300,
        ),
    );
    write(
        "rollout-nested.jsonl",
        codex_turn_lines(
            thread_spawn_meta("nested-1", Some("root-1"), "child-1"),
            "nested-turn",
            "2026-10-03T10:00:30Z",
            "2026-10-03T10:01:00Z",
            250,
        ),
    );
    // Without `session_id` the parent thread is the root.
    write(
        "rollout-parented.jsonl",
        codex_turn_lines(
            thread_spawn_meta("child-2", None, "root-1"),
            "parented-turn",
            "2026-10-03T10:00:50Z",
            "2026-10-03T10:01:10Z",
            100,
        ),
    );
    // Not counted: an aborted child turn, other roots, work outside the window, and approval
    // reviews (guardian), which are harness overhead.
    let mut aborted = codex_turn_lines(
        thread_spawn_meta("child-3", Some("root-1"), "root-1"),
        "aborted-turn",
        "2026-10-03T10:00:55Z",
        "2026-10-03T10:01:05Z",
        5_000,
    );
    aborted.pop();
    aborted.push(codex_line(
        "event_msg",
        json!({"type": "turn_aborted", "turn_id": "aborted-turn"}),
        "2026-10-03T10:01:05Z",
    ));
    write("rollout-aborted.jsonl", aborted);
    write(
        "rollout-other-root.jsonl",
        codex_turn_lines(
            thread_spawn_meta("child-4", Some("root-other"), "root-other"),
            "other-turn",
            "2026-10-03T10:00:30Z",
            "2026-10-03T10:00:50Z",
            777,
        ),
    );
    write(
        "rollout-late.jsonl",
        codex_turn_lines(
            thread_spawn_meta("child-5", Some("root-1"), "root-1"),
            "late-turn",
            "2026-10-03T10:02:30Z",
            "2026-10-03T10:02:50Z",
            888,
        ),
    );
    write(
        "rollout-guardian.jsonl",
        codex_turn_lines(
            json!({"id": "guardian-1", "session_id": "root-1", "parent_thread_id": "root-1", "source": {"subagent": {"other": "guardian"}}}),
            "guardian-turn",
            "2026-10-03T10:00:40Z",
            "2026-10-03T10:00:45Z",
            900,
        ),
    );

    let mut monitor = Monitor::new(sessions);
    let mut latest = std::collections::HashMap::new();
    let mut live = Vec::new();
    let mut poll = |monitor: &mut Monitor,
                    latest: &mut std::collections::HashMap<String, TurnMetric>,
                    now: &str| {
        for _ in 0..6 {
            for record in monitor.poll(time(now)).unwrap() {
                latest.insert(record.id.clone(), record);
            }
            live.extend(monitor.take_live_responses());
        }
    };
    poll(&mut monitor, &mut latest, "2026-10-03T10:02:10Z");
    // Children emit no turn of their own, only the root session's turn is recorded.
    assert_eq!(latest.len(), 1);
    assert_eq!(
        latest.values().next().unwrap().delegated_output_tokens,
        None
    );
    poll(&mut monitor, &mut latest, "2026-10-03T10:02:30Z");
    let turn = latest.values().next().unwrap();
    assert_eq!(latest.len(), 1);
    assert_eq!(turn.output_tokens, 500);
    assert_eq!(turn.delegated_output_tokens, Some(650));
    // Only the root session's response reaches the live stream.
    assert!(!live.is_empty());
    assert!(live.iter().all(|response| response.output_tokens == 500));
}

#[test]
fn codex_child_sessions_report_work_only_and_other_agents_stay_skipped() {
    let new_parser = || crate::parser::CodexEventParser::new("file".into());
    let feed = |parser: &mut crate::parser::CodexEventParser, lines: Vec<Vec<u8>>| {
        let mut turns = Vec::new();
        for line in lines {
            turns.extend(parser.consume(&line));
        }
        turns
    };

    // A thread_spawn child is read, but produces no TurnMetric and no live response.
    let mut child = new_parser();
    let turns = feed(
        &mut child,
        codex_turn_lines(
            thread_spawn_meta("child-1", Some("root-1"), "parent-1"),
            "t",
            "2026-10-03T10:00:00Z",
            "2026-10-03T10:00:30Z",
            300,
        ),
    );
    assert!(turns.is_empty());
    assert!(!crate::parser::JsonlEventParser::excludes_session(&child));
    assert!(child.take_responses().is_empty());
    let root = crate::delegation::root_session_key("codex", "root-1");
    let events = crate::parser::JsonlEventParser::take_delegation_events(&mut child);
    assert_eq!(events.len(), 2);
    let crate::delegation::DelegationEvent::Started {
        work_id,
        root_session,
        started_at,
    } = &events[0]
    else {
        panic!("expected the start of work, got {events:?}");
    };
    assert_eq!(root_session, &root);
    assert_eq!(*started_at, time("2026-10-03T10:00:00Z"));
    assert_eq!(
        events[1],
        crate::delegation::DelegationEvent::Finished {
            work_id: work_id.clone(),
            output_tokens: 300,
            finished_at: time("2026-10-03T10:00:30Z"),
        }
    );

    // The primary turn reports the same root, so the join key is `client|session_id`.
    let mut primary = new_parser();
    let turns = feed(
        &mut primary,
        codex_turn_lines(
            primary_codex_meta("root-1"),
            "t",
            "2026-10-03T10:00:00Z",
            "2026-10-03T10:00:30Z",
            300,
        ),
    );
    let events = crate::parser::JsonlEventParser::take_delegation_events(&mut primary);
    assert_eq!(
        events,
        vec![crate::delegation::DelegationEvent::Turn {
            turn_id: turns[0].id.clone(),
            root_session: root.clone(),
            started_at: time("2026-10-03T10:00:00Z"),
        }]
    );
    // `session_id`, when present on a primary session, is its root.
    let mut keyed = new_parser();
    let mut meta = primary_codex_meta("root-1");
    meta["session_id"] = "root-1".into();
    feed(
        &mut keyed,
        codex_turn_lines(
            meta,
            "t",
            "2026-10-03T10:00:00Z",
            "2026-10-03T10:00:30Z",
            300,
        ),
    );
    assert_eq!(
        crate::parser::JsonlEventParser::take_delegation_events(&mut keyed),
        vec![crate::delegation::DelegationEvent::Turn {
            turn_id: turns[0].id.clone(),
            root_session: root,
            started_at: time("2026-10-03T10:00:00Z"),
        }]
    );

    // An aborted or never-completed child turn is discarded or stays open, never finished.
    let mut aborted = new_parser();
    let mut lines = codex_turn_lines(
        thread_spawn_meta("child-2", None, "root-1"),
        "t",
        "2026-10-03T10:00:00Z",
        "2026-10-03T10:00:30Z",
        300,
    );
    lines.pop();
    lines.push(codex_line(
        "event_msg",
        json!({"type": "turn_aborted", "turn_id": "t"}),
        "2026-10-03T10:00:10Z",
    ));
    feed(&mut aborted, lines);
    let events = crate::parser::JsonlEventParser::take_delegation_events(&mut aborted);
    assert!(matches!(
        events[0],
        crate::delegation::DelegationEvent::Started { .. }
    ));
    assert!(matches!(
        events[1],
        crate::delegation::DelegationEvent::Discarded { .. }
    ));
    assert_eq!(events.len(), 2);
    let mut cut_off = new_parser();
    let mut lines = codex_turn_lines(
        thread_spawn_meta("child-3", None, "root-1"),
        "t",
        "2026-10-03T10:00:00Z",
        "2026-10-03T10:00:30Z",
        300,
    );
    lines.pop();
    feed(&mut cut_off, lines);
    let events = crate::parser::JsonlEventParser::take_delegation_events(&mut cut_off);
    assert_eq!(events.len(), 1);
    // A reader reset settles what the parser started as discarded.
    crate::parser::JsonlEventParser::reset(&mut cut_off, "file".into());
    assert!(matches!(
        crate::parser::JsonlEventParser::take_delegation_events(&mut cut_off)[..],
        [crate::delegation::DelegationEvent::Discarded { .. }]
    ));

    // Other agent kinds are skipped entirely, as before.
    for source in [
        json!({"subagent": {"other": "guardian"}}),
        json!({"subagent": null}),
        json!({"subagent": {"review": null}}),
    ] {
        let mut skipped = new_parser();
        let turns = feed(
            &mut skipped,
            codex_turn_lines(
                json!({"id": "other-1", "session_id": "root-1", "parent_thread_id": "root-1", "source": source}),
                "t",
                "2026-10-03T10:00:00Z",
                "2026-10-03T10:00:30Z",
                300,
            ),
        );
        assert!(turns.is_empty());
        assert!(crate::parser::JsonlEventParser::excludes_session(&skipped));
        assert!(crate::parser::JsonlEventParser::take_delegation_events(&mut skipped).is_empty());
    }
}

#[test]
fn claude_parsers_report_primary_turns_and_subagent_work_through_the_side_channel() {
    use crate::delegation::{root_session_key, DelegationEvent};
    let session = "session-events";
    let mut primary = claude_parser();
    let turn = {
        let mut turn = None;
        for line in [
            with_fields(
                claude_user("2026-10-03T10:00:00Z", "turn", json!("synthetic")),
                json!({"sessionId": session}),
            ),
            with_fields(
                assistant("2026-10-03T10:00:30Z", "call", "end_turn", 50),
                json!({"sessionId": session}),
            ),
        ] {
            turn = turn.or(primary.consume_settled(&line));
        }
        turn.unwrap()
    };
    assert_eq!(
        crate::parser::JsonlEventParser::take_delegation_events(&mut primary),
        vec![DelegationEvent::Turn {
            turn_id: turn.id,
            root_session: root_session_key(CLAUDE_CLIENT, session),
            started_at: time("2026-10-03T10:00:00Z"),
        }]
    );

    let mut subagent = crate::claude_parser::ClaudeTranscriptParser::new_subagent("file".into());
    let mut finished = None;
    for line in finished_subagent(
        session,
        "agent",
        "2026-10-03T10:00:10Z",
        "2026-10-03T10:00:20Z",
        40,
    ) {
        finished = finished.or(subagent.consume_settled(&line));
    }
    let finished = finished.unwrap();
    let events = crate::parser::JsonlEventParser::take_delegation_events(&mut subagent);
    assert_eq!(
        events,
        vec![
            DelegationEvent::Started {
                work_id: finished.id.clone(),
                root_session: root_session_key(CLAUDE_CLIENT, session),
                started_at: time("2026-10-03T10:00:10Z"),
            },
            DelegationEvent::Finished {
                work_id: finished.id,
                output_tokens: 40,
                finished_at: time("2026-10-03T10:00:20Z"),
            },
        ]
    );
}

// --- Tool surface (0.1.18) -------------------------------------------------------------------

use crate::ToolSurface;

#[test]
fn codex_originators_map_to_surface_categories() {
    let cases = [
        (Some("Codex Desktop"), Some(ToolSurface::Desktop)),
        (Some("codex_work_desktop"), Some(ToolSurface::Desktop)),
        (Some("codex_cli_rs"), Some(ToolSurface::Cli)),
        (Some("codex-tui"), Some(ToolSurface::Cli)),
        (Some("codex_tui"), Some(ToolSurface::Cli)),
        (Some("codex_vscode"), Some(ToolSurface::Ide)),
        (Some("codex_exec"), Some(ToolSurface::Sdk)),
        (Some("codex_sdk_ts"), Some(ToolSurface::Sdk)),
        (Some("vibe-codex-executor"), Some(ToolSurface::Other)),
        (Some("buzz-acp"), Some(ToolSurface::Other)),
        (Some("t3code_desktop"), Some(ToolSurface::Other)),
        (Some("bb"), Some(ToolSurface::Other)),
        // Case and surrounding whitespace do not matter; editor hosts match anywhere.
        (Some("  CODEX DESKTOP "), Some(ToolSurface::Desktop)),
        (Some("Codex_CLI_RS"), Some(ToolSurface::Cli)),
        (Some("my-JetBrains-plugin"), Some(ToolSurface::Ide)),
        (Some("cursor-agent"), Some(ToolSurface::Ide)),
        (Some("windsurf"), Some(ToolSurface::Ide)),
        (Some(""), None),
        (Some("   "), None),
        (None, None),
    ];
    for (originator, expected) in cases {
        assert_eq!(
            ToolSurface::from_codex_originator(originator),
            expected,
            "{originator:?}"
        );
    }
}

#[test]
fn claude_entrypoints_map_to_surface_categories() {
    let cases = [
        (Some("cli"), Some(ToolSurface::Cli)),
        (Some("claude-desktop"), Some(ToolSurface::Desktop)),
        (Some("claude-vscode"), Some(ToolSurface::Ide)),
        (Some("claude-jetbrains"), Some(ToolSurface::Ide)),
        (Some("claude-ide"), Some(ToolSurface::Ide)),
        (Some("sdk-ts"), Some(ToolSurface::Sdk)),
        (Some("sdk-py"), Some(ToolSurface::Sdk)),
        (Some("mcp"), Some(ToolSurface::Other)),
        (Some(" CLI "), Some(ToolSurface::Cli)),
        (Some(""), None),
        (None, None),
    ];
    for (entrypoint, expected) in cases {
        assert_eq!(
            ToolSurface::from_claude_entrypoint(entrypoint),
            expected,
            "{entrypoint:?}"
        );
    }
}

fn codex_turn_with_meta(meta: Value) -> TurnMetric {
    let mut parser = crate::parser::CodexEventParser::new("file".into());
    let timestamp = "2026-10-03T10:00:00Z";
    parser.consume(&event("session_meta", meta, timestamp));
    parser.consume(&event(
        "turn_context",
        json!({ "turn_id": "turn", "model": "gpt-test", "effort": "high" }),
        timestamp,
    ));
    parser.consume(&event(
        "token_usage_record",
        json!({ "turn_id": "turn", "turn_token_usage": { "output_tokens": 13 } }),
        timestamp,
    ));
    parser.consume(&event(
        "event_msg",
        json!({ "type": "task_started", "turn_id": "turn", "started_at": timestamp }),
        timestamp,
    ));
    parser
        .consume(&event(
            "event_msg",
            json!({
                "type": "task_complete",
                "turn_id": "turn",
                "started_at": timestamp,
                "completed_at": "2026-10-03T10:00:02Z",
            }),
            "2026-10-03T10:00:02Z",
        ))
        .unwrap()
}

#[test]
fn codex_surface_comes_from_the_originator_never_from_the_source() {
    let surface = |meta: Value| {
        let turn = codex_turn_with_meta(meta);
        let json = serde_json::to_string(&turn).unwrap();
        // Only the category is stored; the originator string itself is never kept.
        assert!(!json.contains("Codex Desktop") && !json.contains("private-tool"));
        turn.surface
    };
    // The desktop app reports source "vscode": the originator decides.
    assert_eq!(
        surface(json!({"id":"s","source":"vscode","originator":"Codex Desktop"})),
        Some(ToolSurface::Desktop)
    );
    assert_eq!(
        surface(json!({"id":"s","source":"cli","originator":"codex_cli_rs"})),
        Some(ToolSurface::Cli)
    );
    assert_eq!(
        surface(json!({"id":"s","source":"cli","originator":"private-tool"})),
        Some(ToolSurface::Other)
    );
    // Without a usable originator the surface is unknown, whatever the source says.
    assert_eq!(surface(json!({"id":"s","source":"vscode"})), None);
    assert_eq!(
        surface(json!({"id":"s","source":"cli","originator":""})),
        None
    );
    assert_eq!(
        surface(json!({"id":"s","source":"cli","originator":7})),
        None
    );
}

fn with_entrypoint(line: Vec<u8>, entrypoint: &str) -> Vec<u8> {
    let mut record: Value = serde_json::from_slice(&line).unwrap();
    record["entrypoint"] = json!(entrypoint);
    serde_json::to_vec(&record).unwrap()
}

#[test]
fn claude_surface_comes_from_the_prompt_record_else_the_assistant_records() {
    let start = "2026-10-03T10:00:00Z";
    let end = "2026-10-03T10:00:10Z";
    let turn = |prompt_entrypoint: Option<&str>, call: Option<&str>, last: Option<&str>| {
        let mut parser = claude_parser();
        let prompt = claude_user(start, "human", json!("synthetic"));
        parser.consume_settled(&match prompt_entrypoint {
            Some(value) => with_entrypoint(prompt, value),
            None => prompt,
        });
        let first = assistant("2026-10-03T10:00:05Z", "call-1", "tool_use", 5);
        parser.consume_settled(&match call {
            Some(value) => with_entrypoint(first, value),
            None => first,
        });
        let final_record = assistant(end, "call-2", "end_turn", 7);
        parser
            .consume_settled(&match last {
                Some(value) => with_entrypoint(final_record, value),
                None => final_record,
            })
            .unwrap()
    };
    let result = turn(Some("cli"), None, None);
    assert_eq!(result.surface, Some(ToolSurface::Cli));
    // The prompt record wins over later assistant records; the first non-empty value wins.
    assert_eq!(
        turn(Some("claude-desktop"), Some("cli"), None).surface,
        Some(ToolSurface::Desktop)
    );
    assert_eq!(
        turn(None, Some("claude-vscode"), Some("cli")).surface,
        Some(ToolSurface::Ide)
    );
    assert_eq!(
        turn(None, None, Some("sdk-ts")).surface,
        Some(ToolSurface::Sdk)
    );
    assert_eq!(
        turn(Some(""), None, Some("mcp")).surface,
        Some(ToolSurface::Other)
    );
    assert_eq!(turn(None, None, None).surface, None);
    // Only the category is kept, never the entrypoint string.
    assert!(
        !serde_json::to_string(&turn(Some("secret-ide-host"), None, None))
            .unwrap()
            .contains("secret-ide-host")
    );
}

#[test]
fn grok_turns_carry_no_surface() {
    let steps = grok_call_steps(&[20_000]);
    assert_eq!(grok_single_record(&steps, 2_000, json!(1)).surface, None);
}

#[test]
fn surface_round_trips_through_history_and_decodes_missing_or_unknown_values() {
    let now = time("2026-10-03T12:00:00Z");
    let directory = TestDir::new();
    let path = directory.path().join("history.json");
    let mut known = metric("known", now - Duration::hours(1));
    known.surface = Some(ToolSurface::Ide);
    let plain = metric("plain", now - Duration::hours(2));
    assert_eq!(plain.surface, None);
    let mut history = History::default();
    history.merge(&[known.clone(), plain.clone()], now);
    history.save(&path).unwrap();
    let loaded = History::load(&path, now).unwrap();
    let by_id = |id: &str| {
        loaded
            .records()
            .iter()
            .find(|r| r.id == id)
            .unwrap()
            .surface
    };
    assert_eq!(by_id("known"), Some(ToolSurface::Ide));
    assert_eq!(by_id("plain"), None);
    let encoded = serde_json::to_value(&known).unwrap();
    assert_eq!(encoded["surface"], "ide");

    // A record saved before the field existed has no key; a value from a future version, or of
    // another type, is unknown rather than a failure that would drop the record.
    let mut legacy = serde_json::to_value(&known).unwrap();
    legacy.as_object_mut().unwrap().remove("surface");
    let restored: TurnMetric = serde_json::from_value(legacy.clone()).unwrap();
    assert_eq!(restored.surface, None);
    for stored in [json!("terminal-v9"), json!(7), json!(["cli"]), Value::Null] {
        legacy["surface"] = stored;
        let restored: TurnMetric = serde_json::from_value(legacy.clone()).unwrap();
        assert_eq!(restored.surface, None);
        assert_eq!(restored.id, "known");
    }
    legacy["surface"] = json!("sdk");
    let restored: TurnMetric = serde_json::from_value(legacy).unwrap();
    assert_eq!(restored.surface, Some(ToolSurface::Sdk));
}

#[test]
fn shared_samples_always_serialize_the_surface() {
    let mut turn = metric("surface", time("2026-10-03T10:00:00Z"));
    let share = |turn: &TurnMetric| {
        serde_json::to_value(crate::SharedSample::from_metric(turn, Uuid::new_v4()).unwrap())
            .unwrap()
    };
    let unknown = share(&turn);
    assert!(unknown.as_object().unwrap().contains_key("surface"));
    assert_eq!(unknown["surface"], Value::Null);
    turn.surface = Some(ToolSurface::Desktop);
    assert_eq!(share(&turn)["surface"], "desktop");
}

// --- Prompt cache (0.1.18) -------------------------------------------------------------------

/// Claude Code usage: `input_tokens` excludes the cached tokens.
fn with_usage(line: Vec<u8>, usage: Value) -> Vec<u8> {
    let mut value: Value = serde_json::from_slice(&line).unwrap();
    for (key, field) in usage.as_object().unwrap() {
        value["message"]["usage"][key] = field.clone();
    }
    serde_json::to_vec(&value).unwrap()
}

fn cache_usage(input: i64, read: i64, create: i64) -> Value {
    json!({
        "input_tokens": input,
        "cache_read_input_tokens": read,
        "cache_creation_input_tokens": create
    })
}

fn prompt_cache(metric: &TurnMetric) -> (Option<i64>, Option<i64>, Option<i64>) {
    (
        metric.input_tokens,
        metric.cache_read_input_tokens,
        metric.cache_write_input_tokens,
    )
}

#[test]
fn claude_prompt_cache_sums_unique_messages_and_takes_repeated_records_once() {
    let mut parser = claude_parser();
    parser.consume_settled(&claude_user(
        "2026-10-03T10:00:00Z",
        "turn",
        json!("synthetic"),
    ));
    // One message is written as several records: only output_tokens grows, the rest repeats.
    for (at, tokens, stop) in [
        ("2026-10-03T10:00:02Z", 10, ""),
        ("2026-10-03T10:00:03Z", 40, ""),
        ("2026-10-03T10:00:04Z", 90, "tool_use"),
    ] {
        parser.consume_settled(&with_usage(
            assistant(at, "call-1", stop, tokens),
            cache_usage(5, 1_000, 200),
        ));
    }
    let result = parser
        .consume_settled(&with_usage(
            assistant("2026-10-03T10:00:10Z", "call-2", "end_turn", 60),
            cache_usage(3, 1_300, 0),
        ))
        .unwrap();
    assert_eq!(result.output_tokens, 150);
    // input = sum(input + read + create) = (5 + 1,000 + 200) + (3 + 1,300 + 0)
    assert_eq!(prompt_cache(&result), (Some(2_508), Some(2_300), Some(200)));
}

#[test]
fn claude_prompt_cache_takes_each_field_from_the_first_record_that_has_it() {
    let mut parser = claude_parser();
    parser.consume_settled(&claude_user(
        "2026-10-03T10:00:00Z",
        "turn",
        json!("synthetic"),
    ));
    parser.consume_settled(&assistant("2026-10-03T10:00:02Z", "call", "", 5));
    let result = parser
        .consume_settled(&with_usage(
            assistant("2026-10-03T10:00:10Z", "call", "end_turn", 50),
            cache_usage(4, 90, 6),
        ))
        .unwrap();
    assert_eq!(prompt_cache(&result), (Some(100), Some(90), Some(6)));
}

#[test]
fn claude_prompt_cache_is_unreported_when_any_counted_message_lacks_a_field() {
    let complete = cache_usage(1, 2, 3);
    let run = |first: Value, second: Value| {
        let mut parser = claude_parser();
        parser.consume_settled(&claude_user(
            "2026-10-03T10:00:00Z",
            "turn",
            json!("synthetic"),
        ));
        parser.consume_settled(&with_usage(
            assistant("2026-10-03T10:00:04Z", "call-1", "tool_use", 20),
            first,
        ));
        parser
            .consume_settled(&with_usage(
                assistant("2026-10-03T10:00:10Z", "call-2", "end_turn", 20),
                second,
            ))
            .unwrap()
    };
    assert_eq!(
        prompt_cache(&run(complete.clone(), complete.clone())),
        (Some(12), Some(4), Some(6))
    );
    for missing in [
        "input_tokens",
        "cache_read_input_tokens",
        "cache_creation_input_tokens",
    ] {
        let mut incomplete = complete.clone();
        incomplete.as_object_mut().unwrap().remove(missing);
        for result in [
            run(incomplete.clone(), complete.clone()),
            run(complete.clone(), incomplete.clone()),
        ] {
            // Missing is not zero: the whole set is unreported, the turn itself still is.
            assert_eq!(result.output_tokens, 40, "{missing}");
            assert_eq!(prompt_cache(&result), (None, None, None), "{missing}");
        }
    }
    let none = run(json!({}), json!({}));
    assert_eq!(prompt_cache(&none), (None, None, None));
}

#[test]
fn claude_subagent_turns_report_prompt_cache_too() {
    let session = "11111111-2222-4333-8444-555555555555";
    let agent = "a1b2c3d4e5f60718";
    let mut parser = crate::claude_parser::ClaudeTranscriptParser::new_subagent("file".into());
    parser.consume_settled(&as_subagent(
        claude_user("2026-10-03T10:00:00Z", "task", json!("synthetic")),
        session,
        agent,
    ));
    parser.consume_settled(&as_subagent(
        with_usage(
            assistant("2026-10-03T10:00:04Z", "sub-1", "tool_use", 10),
            cache_usage(2, 500, 100),
        ),
        session,
        agent,
    ));
    let result = parser
        .consume_settled(&as_subagent(
            with_usage(
                assistant("2026-10-03T10:00:10Z", "sub-2", "end_turn", 30),
                cache_usage(1, 700, 0),
            ),
            session,
            agent,
        ))
        .unwrap();
    assert_eq!(result.source_kind.as_deref(), Some("subagent"));
    assert_eq!(prompt_cache(&result), (Some(1_303), Some(1_200), Some(100)));
    let sample = crate::SharedSample::from_metric(&result, Uuid::new_v4()).unwrap();
    assert_eq!(sample.input_tokens, Some(1_303));
    assert_eq!(sample.cache_write_input_tokens, Some(100));
}

#[test]
fn codex_prompt_cache_comes_from_the_last_turn_token_usage_and_never_reports_a_write() {
    let usage = |at: &str, response: &str, turn_usage: Value| {
        codex_line(
            "token_usage_record",
            json!({
                "turn_id": "turn-1",
                "response_id": response,
                "usage": {"output_tokens": 300},
                "turn_token_usage": turn_usage
            }),
            at,
        )
    };
    let run = |usages: Vec<Vec<u8>>| {
        let mut parser = crate::parser::CodexEventParser::new("file".into());
        let mut turns = Vec::new();
        let mut lines = vec![
            codex_line(
                "session_meta",
                json!({"id": "session-1", "source": "cli", "model_provider": "openai"}),
                "2026-10-03T10:00:00.000Z",
            ),
            codex_line(
                "event_msg",
                json!({"type": "task_started", "turn_id": "turn-1"}),
                "2026-10-03T10:00:00.000Z",
            ),
        ];
        lines.extend(usages);
        lines.push(codex_line(
            "event_msg",
            json!({"type": "task_complete", "turn_id": "turn-1", "duration_ms": 25000}),
            "2026-10-03T10:00:25.100Z",
        ));
        for line in lines {
            turns.extend(parser.consume(&line));
        }
        assert_eq!(turns.len(), 1);
        turns.remove(0)
    };
    // Cumulative: the last record wins, and Codex's input already includes the cached tokens.
    let result = run(vec![
        usage(
            "2026-10-03T10:00:04Z",
            "resp-1",
            json!({"output_tokens": 300, "input_tokens": 30_000, "cached_input_tokens": 12_000, "cache_creation_input_tokens": 0}),
        ),
        usage(
            "2026-10-03T10:00:12Z",
            "resp-2",
            json!({"output_tokens": 700, "input_tokens": 80_000, "cached_input_tokens": 61_000, "cache_creation_input_tokens": 0}),
        ),
    ]);
    assert_eq!(result.output_tokens, 700);
    assert_eq!(prompt_cache(&result), (Some(80_000), Some(61_000), None));
    let sample =
        crate::SharedSample::from_metric(&result.with_delegated_output_tokens(0), Uuid::new_v4())
            .unwrap();
    assert_eq!(sample.cache_write_input_tokens, None);

    // A record without input counts (or with a cache larger than the input) reports nothing.
    for incomplete in [
        json!({"output_tokens": 50, "cached_input_tokens": 10}),
        json!({"output_tokens": 50, "input_tokens": 100}),
        json!({"output_tokens": 50, "input_tokens": 100, "cached_input_tokens": 101}),
    ] {
        let result = run(vec![usage("2026-10-03T10:00:04Z", "resp-1", incomplete)]);
        assert_eq!(prompt_cache(&result), (None, None, None));
    }
    let zero = run(vec![usage(
        "2026-10-03T10:00:04Z",
        "resp-1",
        json!({"output_tokens": 50, "input_tokens": 100, "cached_input_tokens": 0}),
    )]);
    assert_eq!(prompt_cache(&zero), (Some(100), Some(0), None));
}

#[test]
fn grok_prompt_cache_comes_from_the_ledger_row_and_never_reports_a_write() {
    let run = |row_fields: Value| {
        let temp = TestDir::new();
        let mut usage = grok_usage("session-id", 7, 50);
        for (key, value) in row_fields.as_object().unwrap() {
            usage["turns"][0][key] = value.clone();
        }
        write_grok_session(
            temp.path(),
            "session-id",
            &grok_turn_events("session-id", 7, "completed"),
            &usage,
        );
        let now = time("2026-10-03T10:00:06Z");
        let mut monitor = GrokMonitor::new(temp.path().to_path_buf());
        let mut found = Vec::new();
        for _ in 0..3 {
            found.extend(monitor.poll(now).unwrap());
            if !found.is_empty() {
                break;
            }
        }
        assert_eq!(found.len(), 1);
        found.remove(0)
    };
    // Grok's inputTokens already includes the cached tokens; cacheCreationTokens is always 0.
    let result =
        run(json!({"inputTokens": 90_000, "cachedReadTokens": 70_000, "cacheCreationTokens": 0}));
    assert_eq!(prompt_cache(&result), (Some(90_000), Some(70_000), None));
    let sample = crate::SharedSample::from_metric(&result, Uuid::new_v4()).unwrap();
    assert_eq!(sample.cache_write_input_tokens, None);
    assert!(serde_json::to_value(&sample).unwrap()["cacheWriteInputTokens"].is_null());

    for incomplete in [
        json!({}),
        json!({"inputTokens": 90_000}),
        json!({"cachedReadTokens": 70_000}),
        json!({"inputTokens": 100, "cachedReadTokens": 101}),
        json!({"inputTokens": "90000", "cachedReadTokens": 1}),
    ] {
        let result = run(incomplete);
        assert_eq!(result.output_tokens, 50);
        assert_eq!(prompt_cache(&result), (None, None, None));
    }
    assert_eq!(
        prompt_cache(&run(json!({"inputTokens": 100, "cachedReadTokens": 0}))),
        (Some(100), Some(0), None)
    );
}

#[test]
fn prompt_cache_fields_are_consistent_or_all_none() {
    use crate::model::consistent_prompt_cache as consistent;
    assert_eq!(
        consistent(Some(100), Some(100), Some(0)),
        (Some(100), Some(100), Some(0))
    );
    assert_eq!(
        consistent(Some(100), Some(0), None),
        (Some(100), Some(0), None)
    );
    for inconsistent in [
        consistent(Some(100), Some(101), Some(5)),
        consistent(Some(100), None, None),
        consistent(None, Some(10), None),
        consistent(None, None, Some(5)),
        consistent(Some(100), None, Some(5)),
        consistent(Some(-1), Some(0), None),
        consistent(Some(100), Some(-1), None),
        consistent(Some(100), Some(10), Some(-1)),
    ] {
        assert_eq!(inconsistent, (None, None, None));
    }
    let mut metric = metric("cache", time("2026-10-03T10:00:00Z"));
    metric.set_prompt_cache(Some(10), Some(11), Some(2));
    assert_eq!(prompt_cache(&metric), (None, None, None));
    metric.set_prompt_cache(Some(10), Some(4), Some(2));
    assert_eq!(prompt_cache(&metric), (Some(10), Some(4), Some(2)));
    // A copy with its delegated total settled keeps them.
    assert_eq!(
        prompt_cache(&metric.with_delegated_output_tokens(5)),
        (Some(10), Some(4), Some(2))
    );
}

#[test]
fn shared_samples_always_encode_prompt_cache_keys_and_never_share_an_inconsistent_set() {
    let now = time("2026-10-03T10:00:00Z");
    let none = crate::SharedSample::from_metric(&metric("none", now), Uuid::new_v4()).unwrap();
    let json = serde_json::to_value(&none).unwrap();
    for key in [
        "inputTokens",
        "cacheReadInputTokens",
        "cacheWriteInputTokens",
    ] {
        assert!(json.get(key).unwrap().is_null(), "{key} is explicit null");
    }
    let mut reported = metric("reported", now);
    reported.set_prompt_cache(Some(52_000), Some(40_000), Some(9_000));
    let json =
        serde_json::to_value(crate::SharedSample::from_metric(&reported, Uuid::new_v4()).unwrap())
            .unwrap();
    assert_eq!(json["inputTokens"], 52_000);
    assert_eq!(json["cacheReadInputTokens"], 40_000);
    assert_eq!(json["cacheWriteInputTokens"], 9_000);
    // Fields set directly (not through set_prompt_cache) are still vetted at the boundary.
    let mut bad = metric("bad", now);
    bad.input_tokens = Some(10);
    bad.cache_read_input_tokens = Some(11);
    let sample = crate::SharedSample::from_metric(&bad, Uuid::new_v4()).unwrap();
    assert_eq!(
        (
            sample.input_tokens,
            sample.cache_read_input_tokens,
            sample.cache_write_input_tokens
        ),
        (None, None, None)
    );
}

#[test]
fn history_without_prompt_cache_fields_decodes_and_inconsistent_stored_sets_are_dropped() {
    let mut stored = metric("stored", time("2026-10-03T10:00:00Z"));
    stored.set_prompt_cache(Some(100), Some(60), Some(10));
    let mut legacy = serde_json::to_value(&stored).unwrap();
    for key in [
        "inputTokens",
        "cacheReadInputTokens",
        "cacheWriteInputTokens",
    ] {
        legacy.as_object_mut().unwrap().remove(key);
    }
    let restored: TurnMetric = serde_json::from_value(legacy).unwrap();
    assert_eq!(prompt_cache(&restored), (None, None, None));
    // Round trip keeps them.
    let round: TurnMetric = serde_json::from_value(serde_json::to_value(&stored).unwrap()).unwrap();
    assert_eq!(prompt_cache(&round), (Some(100), Some(60), Some(10)));

    // A persisted record whose set is inconsistent loads as not reported.
    let temp = TestDir::new();
    let path = temp.path().join("history.json");
    let now = time("2026-10-03T10:30:00Z");
    let mut bad = serde_json::to_value(metric("bad", time("2026-10-03T10:00:00Z"))).unwrap();
    bad["inputTokens"] = json!(10);
    bad["cacheReadInputTokens"] = json!(11);
    bad["cacheWriteInputTokens"] = json!(2);
    fs::write(
        &path,
        serde_json::to_vec(&json!({"schemaVersion": 1, "records": [bad]})).unwrap(),
    )
    .unwrap();
    let history = History::load(&path, now).unwrap();
    assert_eq!(history.records().len(), 1);
    assert_eq!(prompt_cache(&history.records()[0]), (None, None, None));
}

// --- Change notes, discovery cadence and launch checkpoints ---

/// Timestamps in the files carry whole seconds; keep expectations equal to them.
fn whole_seconds(at: DateTime<Utc>) -> DateTime<Utc> {
    DateTime::from_timestamp(at.timestamp(), 0).unwrap()
}

fn secs(at: DateTime<Utc>) -> String {
    at.to_rfc3339_opts(chrono::SecondsFormat::Secs, true)
}

/// A Codex rollout of finished turns `(turn id, start, end, output tokens)`.
fn codex_session_file(id: &str, turns: &[(&str, DateTime<Utc>, DateTime<Utc>, i64)]) -> Vec<u8> {
    let mut lines = Vec::new();
    for (index, (turn, start, end, tokens)) in turns.iter().enumerate() {
        let turn_lines = codex_turn_lines(
            primary_codex_meta(id),
            turn,
            &secs(*start),
            &secs(*end),
            *tokens,
        );
        lines.extend(turn_lines.into_iter().skip(usize::from(index > 0)));
    }
    jsonl(&lines)
}

/// The lines of one more turn for an existing rollout (no header).
fn codex_turn_append(turn: &str, start: DateTime<Utc>, end: DateTime<Utc>, tokens: i64) -> Vec<u8> {
    let lines = codex_turn_lines(
        primary_codex_meta("unused"),
        turn,
        &secs(start),
        &secs(end),
        tokens,
    );
    jsonl(&lines[1..])
}

fn append_to(path: &Path, bytes: &[u8]) {
    fs::OpenOptions::new()
        .append(true)
        .open(path)
        .unwrap()
        .write_all(bytes)
        .unwrap();
}

/// Polls `count` times at `now` and collects what comes back.
fn poll_n(monitor: &mut Monitor, now: DateTime<Utc>, count: usize) -> Vec<TurnMetric> {
    let mut found = Vec::new();
    for _ in 0..count {
        found.extend(monitor.poll(now).unwrap());
    }
    found
}

/// Polls until nothing is pending at `now` (replay and settling done).
fn settle(monitor: &mut Monitor, now: DateTime<Utc>) -> Vec<TurnMetric> {
    let mut found = Vec::new();
    for _ in 0..60 {
        found.extend(monitor.poll(now).unwrap());
        if monitor.next_poll_deadline(now).is_none() {
            return found;
        }
    }
    panic!("the monitor never went idle");
}

struct CodexFixture {
    _temp: TestDir,
    root: PathBuf,
    session: PathBuf,
    base: DateTime<Utc>,
}

impl CodexFixture {
    /// One finished turn written an hour ago (by its timestamps) to a fresh rollout.
    fn new() -> Self {
        let temp = TestDir::new();
        let root = temp.path().join("sessions");
        fs::create_dir_all(&root).unwrap();
        let base = whole_seconds(Utc::now() - Duration::hours(1));
        let session = root.join("rollout.jsonl");
        fs::write(
            &session,
            codex_session_file(
                "session-a",
                &[("turn-1", base, base + Duration::seconds(10), 400)],
            ),
        )
        .unwrap();
        Self {
            _temp: temp,
            root,
            session,
            base,
        }
    }

    /// Late enough for the delegation to settle and for a checkpoint to apply.
    fn later(&self) -> DateTime<Utc> {
        Utc::now() + Duration::hours(1)
    }
}

#[test]
fn a_reported_append_is_read_at_once_and_an_unreported_one_waits_for_the_safety_net() {
    let fixture = CodexFixture::new();
    let now = fixture.later();
    let mut monitor = Monitor::new(fixture.root.clone());
    assert_eq!(settle(&mut monitor, now).len(), 1);

    let second = fixture.base + Duration::seconds(60);
    append_to(
        &fixture.session,
        &codex_turn_append("turn-2", second, second + Duration::seconds(10), 500),
    );
    // Nothing was reported: the caught-up file is not opened and the next poll deadline stays empty.
    assert!(poll_n(&mut monitor, now + Duration::seconds(2), 3).is_empty());
    assert_eq!(monitor.bytes_read_last_poll(), 0);
    assert_eq!(monitor.next_poll_deadline(now), None);

    assert!(monitor.note_changes(&changed(&[&fixture.session])));
    assert_eq!(monitor.next_poll_deadline(now), Some(now));
    let found = settle(&mut monitor, now + Duration::seconds(3));
    assert_eq!(
        found
            .iter()
            .map(|turn| turn.output_tokens)
            .collect::<Vec<_>>(),
        [500]
    );

    // A write the watcher missed is caught by the safety net.
    let third = fixture.base + Duration::seconds(120);
    append_to(
        &fixture.session,
        &codex_turn_append("turn-3", third, third + Duration::seconds(10), 600),
    );
    assert!(poll_n(&mut monitor, now + Duration::seconds(299), 3).is_empty());
    let found = settle(&mut monitor, now + Duration::seconds(303));
    assert_eq!(
        found
            .iter()
            .map(|turn| turn.output_tokens)
            .collect::<Vec<_>>(),
        [600]
    );
}

#[test]
fn a_noted_new_file_is_discovered_and_excluded_paths_are_ignored() {
    let fixture = CodexFixture::new();
    let now = fixture.later();
    let mut monitor = Monitor::new(fixture.root.clone());
    settle(&mut monitor, now);

    let hidden = fixture.root.join(".hidden");
    fs::create_dir_all(&hidden).unwrap();
    let ignored = [
        fixture.root.join("notes.txt"),
        hidden.join("rollout-hidden.jsonl"),
        fixture.root.parent().unwrap().join("outside.jsonl"),
        fixture.root.join("missing.jsonl"),
    ];
    for path in &ignored[..3] {
        fs::write(path, b"{}\n").unwrap();
    }
    let paths: Vec<&Path> = ignored.iter().map(PathBuf::as_path).collect();
    assert!(!monitor.note_changes(&changed(&paths)));
    assert_eq!(monitor.next_poll_deadline(now), None);

    let created = fixture.root.join("second.jsonl");
    let start = fixture.base + Duration::seconds(30);
    fs::write(
        &created,
        codex_session_file(
            "session-b",
            &[("turn-b", start, start + Duration::seconds(10), 450)],
        ),
    )
    .unwrap();
    assert!(monitor.note_changes(&changed(&[&created])));
    let found = settle(&mut monitor, now);
    assert_eq!(
        found
            .iter()
            .map(|turn| turn.output_tokens)
            .collect::<Vec<_>>(),
        [450]
    );
}

#[test]
fn claude_primary_and_subagent_monitors_each_note_only_their_own_transcripts() {
    let temp = TestDir::new();
    let projects = temp.path().join("projects");
    let primary = projects.join("project-a/session.jsonl");
    let subagent = projects.join("project-a/session/subagents/agent-1.jsonl");
    fs::create_dir_all(subagent.parent().unwrap()).unwrap();
    fs::write(&primary, b"{}\n").unwrap();
    fs::write(&subagent, b"{}\n").unwrap();

    let mut primary_monitor = Monitor::new_claude(projects.clone());
    let mut subagent_monitor = Monitor::new_claude_subagents(projects);
    assert!(!primary_monitor.note_changes(&changed(&[&subagent])));
    assert!(!subagent_monitor.note_changes(&changed(&[&primary])));
    assert!(primary_monitor.note_changes(&changed(&[&primary])));
    assert!(subagent_monitor.note_changes(&changed(&[&subagent])));
}

#[test]
fn a_rescan_request_triggers_discovery_of_files_nobody_reported() {
    let fixture = CodexFixture::new();
    let now = fixture.later();
    let mut monitor = Monitor::new(fixture.root.clone());
    settle(&mut monitor, now);

    let start = fixture.base + Duration::seconds(30);
    fs::write(
        fixture.root.join("second.jsonl"),
        codex_session_file(
            "session-b",
            &[("turn-b", start, start + Duration::seconds(10), 450)],
        ),
    )
    .unwrap();
    assert!(poll_n(&mut monitor, now, 3).is_empty());
    assert!(monitor.note_changes(&SourceChange {
        paths: HashSet::new(),
        must_rescan: true
    }));
    let found = settle(&mut monitor, now);
    assert_eq!(found.len(), 1);
}

#[test]
fn an_empty_or_missing_root_is_not_walked_on_every_poll() {
    let temp = TestDir::new();
    let now = Utc::now() + Duration::hours(1);
    let root = temp.path().join("sessions");
    let mut monitor = Monitor::new(root.clone());
    // A missing root fails its one discovery and then costs nothing but a stat.
    assert_eq!(
        monitor.poll(now).unwrap_err().kind(),
        std::io::ErrorKind::NotFound
    );
    assert!(monitor.poll(now + Duration::seconds(2)).unwrap().is_empty());
    assert!(!monitor.root_exists());
    assert_eq!(monitor.next_poll_deadline(now), None);

    // The root appearing is noticed by the next poll.
    fs::create_dir_all(&root).unwrap();
    assert!(monitor.root_exists());
    let start = whole_seconds(Utc::now() - Duration::hours(1));
    let rollout = root.join("rollout.jsonl");
    fs::write(
        &rollout,
        codex_session_file("s", &[("t", start, start + Duration::seconds(10), 400)]),
    )
    .unwrap();
    assert_eq!(settle(&mut monitor, now + Duration::seconds(4)).len(), 1);

    // An empty root is walked once: a file added later is not found until the net or a note.
    let empty = temp.path().join("empty");
    fs::create_dir_all(&empty).unwrap();
    let mut monitor = Monitor::new(empty.clone());
    assert!(poll_n(&mut monitor, now, 2).is_empty());
    fs::write(
        empty.join("late.jsonl"),
        codex_session_file("s", &[("t", start, start + Duration::seconds(10), 400)]),
    )
    .unwrap();
    assert!(poll_n(&mut monitor, now + Duration::seconds(100), 3).is_empty());
    assert_eq!(monitor.next_poll_deadline(now), None);
    assert_eq!(settle(&mut monitor, now + Duration::seconds(300)).len(), 1);
}

#[test]
fn idle_polls_open_no_caught_up_file() {
    let fixture = CodexFixture::new();
    let now = fixture.later();
    let mut monitor = Monitor::new(fixture.root.clone());
    settle(&mut monitor, now);

    // Opening the file again would fail and ask for a discovery, which the deadline would show.
    fs::remove_file(&fixture.session).unwrap();
    for step in 1..10 {
        assert!(monitor
            .poll(now + Duration::seconds(step))
            .unwrap()
            .is_empty());
        assert_eq!(monitor.bytes_read_last_poll(), 0);
        assert_eq!(monitor.next_poll_deadline(now), None);
    }
    // A watcher noting the vanished file prunes it by discovery.
    assert!(monitor.note_changes(&changed(&[&fixture.session])));
    assert_eq!(monitor.next_poll_deadline(now), Some(now));
    assert!(monitor.poll(now).unwrap().is_empty());
    assert_eq!(monitor.next_poll_deadline(now), None);
}

#[test]
fn poll_deadlines_run_from_replay_to_the_settle_time_to_none() {
    let temp = TestDir::new();
    let root = temp.path().join("sessions");
    fs::create_dir_all(&root).unwrap();
    // A rollout larger than the recent tail, so an archive reader replays it.
    let start = whole_seconds(Utc::now() - Duration::minutes(10));
    let end = start + Duration::seconds(10);
    let mut contents = codex_session_file("s", &[("t", start, end, 400)]);
    for _ in 0..8_000 {
        contents.extend_from_slice(b"{\"type\":\"ignored_event\",\"payload\":{}}\n");
    }
    fs::write(root.join("rollout.jsonl"), contents).unwrap();

    let now = end + Duration::seconds(5);
    let mut monitor = Monitor::new(root);
    monitor.poll(now).unwrap();
    assert_eq!(
        monitor.next_poll_deadline(now),
        Some(now),
        "replay is under way"
    );
    let mut found = Vec::new();
    for _ in 0..40 {
        if monitor.next_poll_deadline(now) != Some(now) {
            break;
        }
        found.extend(monitor.poll(now).unwrap());
    }
    // The turn is read but its delegated output settles 30 s after it ended.
    assert_eq!(
        monitor.next_poll_deadline(now),
        Some(end + Duration::seconds(30))
    );
    assert!(found
        .iter()
        .all(|turn| turn.delegated_output_tokens.is_none()));
    let found = monitor.poll(end + Duration::seconds(30)).unwrap();
    assert_eq!(found[0].delegated_output_tokens, Some(0));
    assert_eq!(
        monitor.next_poll_deadline(end + Duration::seconds(30)),
        None
    );
}

fn claude_turn(
    session: &str,
    id: &str,
    start: DateTime<Utc>,
    end: DateTime<Utc>,
    tokens: i64,
) -> Vec<Vec<u8>> {
    let with_session = |line| with_fields(line, json!({"sessionId": session}));
    vec![
        with_session(claude_user(
            &secs(start),
            &format!("{id}-user"),
            json!("synthetic"),
        )),
        with_session(assistant(
            &secs(end),
            &format!("{id}-call"),
            "end_turn",
            tokens,
        )),
    ]
}

#[test]
fn a_claude_monitor_polls_once_more_after_a_read_so_its_parser_can_close_a_waiting_turn() {
    let temp = TestDir::new();
    let projects = temp.path().join("projects");
    fs::create_dir_all(projects.join("project-a")).unwrap();
    let start = whole_seconds(Utc::now() - Duration::hours(1));
    let path = projects.join("project-a/session.jsonl");
    fs::write(
        &path,
        jsonl(&claude_turn(
            "session-1",
            "turn-1",
            start,
            start + Duration::seconds(10),
            400,
        )),
    )
    .unwrap();

    let now = Utc::now() + Duration::hours(1);
    let mut monitor = Monitor::new_claude(projects);
    for _ in 0..6 {
        monitor.poll(now).unwrap();
    }
    // Everything is read, but the parser may still hold a turn it waited to close.
    assert_eq!(
        monitor.next_poll_deadline(now),
        Some(now + Duration::seconds(31))
    );
    assert!(monitor.checkpoints().unwrap().is_empty());
    monitor.poll(now + Duration::seconds(31)).unwrap();
    assert_eq!(monitor.next_poll_deadline(now), None);
    assert_eq!(monitor.checkpoints().unwrap().len(), 1);
}

#[test]
fn launch_checkpoints_skip_a_fully_read_file_and_a_later_append_still_resolves_the_model() {
    for large in [false, true] {
        let fixture = CodexFixture::new();
        if large {
            // Past the recent tail, a launch would otherwise replay the whole file.
            let mut filler = Vec::new();
            for _ in 0..8_000 {
                filler.extend_from_slice(b"{\"type\":\"ignored_event\",\"payload\":{}}\n");
            }
            append_to(&fixture.session, &filler);
        }
        let now = fixture.later();
        let mut first = Monitor::new(fixture.root.clone());
        // The tail and the replay reader may both report the turn; it is one turn by its id.
        let ids: HashSet<String> = settle(&mut first, now)
            .into_iter()
            .map(|turn| turn.id)
            .collect();
        assert_eq!(ids.len(), 1);
        let checkpoints = first.checkpoints().unwrap();
        assert_eq!(checkpoints.len(), 1);

        let mut second = Monitor::new(fixture.root.clone());
        second.set_checkpoints(checkpoints);
        assert!(second.poll(now).unwrap().is_empty());
        assert_eq!(second.bytes_read_last_poll(), 0);
        assert_eq!(second.next_poll_deadline(now), None);
        assert_eq!(
            second.checkpoints().unwrap().len(),
            1,
            "the restored file stays checkpointed"
        );
        assert!(poll_n(&mut second, now + Duration::seconds(2), 3).is_empty());
        assert_eq!(second.bytes_read_last_poll(), 0);

        let start = fixture.base + Duration::seconds(60);
        append_to(
            &fixture.session,
            &codex_turn_append("turn-2", start, start + Duration::seconds(10), 700),
        );
        assert!(second.note_changes(&changed(&[&fixture.session])));
        let found = settle(&mut second, now + Duration::seconds(5));
        assert_eq!(found.len(), 1);
        assert_eq!(found[0].output_tokens, 700);
        assert_eq!(found[0].model.as_deref(), Some("gpt-test"));
        assert_eq!(found[0].source_kind.as_deref(), Some("primary"));
    }
}

#[test]
fn launch_checkpoints_also_resume_claude_transcripts() {
    let temp = TestDir::new();
    let projects = temp.path().join("projects");
    fs::create_dir_all(projects.join("project-a")).unwrap();
    let start = whole_seconds(Utc::now() - Duration::hours(1));
    let path = projects.join("project-a/session.jsonl");
    fs::write(
        &path,
        jsonl(&claude_turn(
            "session-1",
            "turn-1",
            start,
            start + Duration::seconds(10),
            400,
        )),
    )
    .unwrap();

    let now = Utc::now() + Duration::hours(1);
    let mut first = Monitor::new_claude(projects.clone());
    let mut found = poll_n(&mut first, now, 6);
    found.extend(first.poll(now + Duration::seconds(31)).unwrap());
    assert_eq!(found.len(), 1);
    let checkpoints = first.checkpoints().unwrap();
    assert_eq!(checkpoints.len(), 1);

    let mut second = Monitor::new_claude(projects);
    second.set_checkpoints(checkpoints);
    assert!(second.poll(now).unwrap().is_empty());
    assert_eq!(second.bytes_read_last_poll(), 0);
    assert_eq!(second.next_poll_deadline(now), None);

    let next = start + Duration::seconds(60);
    append_to(
        &path,
        &jsonl(&claude_turn(
            "session-1",
            "turn-2",
            next,
            next + Duration::seconds(10),
            800,
        )),
    );
    assert!(second.note_changes(&changed(&[&path])));
    let mut found = poll_n(&mut second, now + Duration::seconds(5), 6);
    found.extend(second.poll(now + Duration::seconds(40)).unwrap());
    assert_eq!(found.len(), 1);
    assert_eq!(found[0].output_tokens, 800);
    assert_eq!(found[0].model.as_deref(), Some("claude-model"));
}

#[test]
fn a_checkpoint_that_does_not_match_the_file_falls_back_to_a_full_read() {
    #[derive(Clone, Copy, Debug)]
    enum Mismatch {
        Size,
        Modified,
        Replaced,
        Version,
        TooRecent,
    }
    for mismatch in [
        Mismatch::Size,
        Mismatch::Modified,
        Mismatch::Replaced,
        Mismatch::Version,
        Mismatch::TooRecent,
    ] {
        let fixture = CodexFixture::new();
        let now = fixture.later();
        let mut first = Monitor::new(fixture.root.clone());
        settle(&mut first, now);
        let mut checkpoints = first.checkpoints().unwrap();
        let original = fs::metadata(&fixture.session).unwrap().modified().unwrap();
        let mut poll_at = now;
        match mismatch {
            Mismatch::Size => append_to(
                &fixture.session,
                b"{\"type\":\"ignored_event\",\"payload\":{}}\n",
            ),
            Mismatch::Modified => fs::OpenOptions::new()
                .write(true)
                .open(&fixture.session)
                .unwrap()
                .set_modified(original + StdDuration::from_secs(60))
                .unwrap(),
            Mismatch::Replaced => {
                let copy = fixture.root.join("copy.tmp");
                #[cfg(windows)]
                let (original_created, original_identity) = {
                    let metadata = fs::metadata(&fixture.session).unwrap();
                    (
                        metadata.created().unwrap(),
                        crate::reader::file_identity(&metadata).unwrap(),
                    )
                };
                fs::write(&copy, fs::read(&fixture.session).unwrap()).unwrap();
                fs::rename(&copy, &fixture.session).unwrap();
                #[cfg(windows)]
                {
                    use std::os::windows::fs::FileTimesExt;
                    fs::OpenOptions::new()
                        .write(true)
                        .open(&fixture.session)
                        .unwrap()
                        .set_times(
                            FileTimes::new()
                                .set_created(original_created + StdDuration::from_secs(2)),
                        )
                        .unwrap();
                    let replacement_metadata = fs::metadata(&fixture.session).unwrap();
                    assert_ne!(
                        crate::reader::file_identity(&replacement_metadata),
                        Some(original_identity),
                        "replacement fixture must have a different file identity"
                    );
                }
                fs::OpenOptions::new()
                    .write(true)
                    .open(&fixture.session)
                    .unwrap()
                    .set_modified(original)
                    .unwrap();
            }
            Mismatch::Version => checkpoints[0].version_key.push_str("-changed"),
            Mismatch::TooRecent => poll_at = Utc::now() + Duration::seconds(60),
        }
        let mut second = Monitor::new(fixture.root.clone());
        second.set_checkpoints(checkpoints);
        let found = settle(&mut second, poll_at);
        assert_eq!(found.len(), 1, "{mismatch:?} must read the file again");
        assert_eq!(found[0].output_tokens, 400, "{mismatch:?}");
    }
}

#[test]
fn checkpoints_keep_the_saved_set_while_a_primary_turn_waits_for_its_delegated_output() {
    let fixture = CodexFixture::new();
    let end = fixture.base + Duration::seconds(10);
    let mut monitor = Monitor::new(fixture.root.clone());
    assert!(monitor.checkpoints().is_none(), "nothing is enumerated yet");
    // The turn ended 5 s ago: its delegated output is not final.
    let now = end + Duration::seconds(5);
    for _ in 0..4 {
        monitor.poll(now).unwrap();
    }
    assert!(monitor.checkpoints().is_none());
    assert!(monitor.poll(end + Duration::seconds(30)).unwrap().len() == 1);
    let checkpoints = monitor.checkpoints().unwrap();
    assert_eq!(checkpoints.len(), 1);

    // The Claude pair shares one tracker held by the owner, which keeps the saved set while a
    // Claude turn is pending.
    let temp = TestDir::new();
    let (codex, claude, grok) = (
        temp.path().join("c"),
        temp.path().join("p"),
        temp.path().join("g"),
    );
    fs::create_dir_all(claude.join("project-a")).unwrap();
    let start = whole_seconds(Utc::now() - Duration::minutes(30));
    let end = start + Duration::seconds(10);
    fs::write(
        claude.join("project-a/session.jsonl"),
        jsonl(&claude_turn("session-1", "turn-1", start, end, 400)),
    )
    .unwrap();
    let mut sources = SourceMonitor::new(
        codex,
        claude,
        grok.clone(),
        grok.with_file_name("gemini"),
        grok.with_file_name("opencode"),
    );
    let previous = crate::SourceCheckpoints {
        claude_primary: checkpoints.clone(),
        ..Default::default()
    };
    let now = end + Duration::seconds(20);
    for _ in 0..6 {
        sources.poll(now).unwrap();
    }
    assert_eq!(sources.checkpoints(&previous).claude_primary, checkpoints);
    assert_eq!(
        sources.next_poll_deadline(now),
        Some(end + Duration::seconds(30))
    );
    // Settled, and past the parser's flush poll.
    for _ in 0..3 {
        sources.poll(end + Duration::seconds(60)).unwrap();
    }
    let settled = sources.checkpoints(&previous);
    assert_eq!(settled.claude_primary.len(), 1);
    assert_ne!(settled.claude_primary, checkpoints);
}

#[test]
fn history_round_trips_checkpoints_and_loads_files_without_them() {
    let fixture = CodexFixture::new();
    let now = fixture.later();
    let mut monitor = Monitor::new(fixture.root.clone());
    settle(&mut monitor, now);
    let saved = crate::SourceCheckpoints {
        codex: monitor.checkpoints().unwrap(),
        ..Default::default()
    };

    let temp = TestDir::new();
    let path = temp.path().join("history.json");
    let mut history = History::default();
    history.merge(&[metric("kept", now - Duration::minutes(5))], now);
    history.set_checkpoints(saved.clone(), now);
    history.save(&path).unwrap();
    let text = fs::read_to_string(&path).unwrap();
    assert!(
        !text.contains("rollout.jsonl"),
        "checkpoints never store source paths"
    );
    let loaded = History::load(&path, now).unwrap();
    assert_eq!(loaded.records().len(), 1);
    assert_eq!(loaded.checkpoints(), &saved);

    // A file saved before checkpoints existed loads with none, and without any a save omits the key.
    fs::write(&path, br#"{"schemaVersion":1,"records":[]}"#).unwrap();
    let old = History::load(&path, now).unwrap();
    assert!(old.checkpoints().is_empty());
    old.save(&path).unwrap();
    assert!(!fs::read_to_string(&path).unwrap().contains("checkpoints"));

    // An unknown key does not stop a load (what an older app does with the new one).
    let mut value: Value = serde_json::to_value(&json!({"schemaVersion":1,"records":[]})).unwrap();
    value["futureField"] = json!(true);
    fs::write(&path, serde_json::to_vec(&value).unwrap()).unwrap();
    assert!(History::load(&path, now).is_ok());
}

#[test]
fn history_bounds_checkpoints_by_age_and_file_count() {
    let now = Utc::now();
    let checkpoint = |index: usize, age: Duration| -> crate::SourceFileCheckpoint {
        serde_json::from_value(json!({
            "pathDigest": format!("{index:064}"),
            "identity": null,
            "size": 1,
            "modifiedAt": now - age,
            "versionKey": "v",
        }))
        .unwrap()
    };
    let mut codex: Vec<_> = (0..2_100)
        .map(|index| checkpoint(index, Duration::minutes(index as i64)))
        .collect();
    codex.push(checkpoint(9_999, Duration::days(8)));
    let mut history = History::default();
    history.set_checkpoints(
        crate::SourceCheckpoints {
            codex,
            ..Default::default()
        },
        now,
    );
    let kept = &history.checkpoints().codex;
    assert_eq!(kept.len(), 2_000);
    assert!(kept
        .iter()
        .all(|entry| entry.path_digest != format!("{:064}", 9_999)));
    assert_eq!(kept[0].path_digest, format!("{:064}", 0), "newest first");
}

fn grok_empty_usage(session_id: &str) -> Value {
    json!({"sessionId": session_id, "updatedAt": "2026-10-03T10:00:05Z", "session": {}, "turns": []})
}

/// Polls until the Grok monitor has nothing pending at `now`.
fn grok_settle(monitor: &mut GrokMonitor, now: DateTime<Utc>) -> Vec<TurnMetric> {
    let mut found = Vec::new();
    for _ in 0..40 {
        found.extend(monitor.poll(now).unwrap());
        if monitor.next_poll_deadline(now).is_none() {
            return found;
        }
    }
    panic!("the Grok monitor never went idle");
}

#[test]
fn grok_idle_polls_read_nothing_and_a_noted_change_is_serviced() {
    let temp = TestDir::new();
    let root = temp.path();
    let now = time("2026-10-03T10:00:06Z");
    write_grok_session(
        root,
        "first",
        &grok_turn_events("first", 0, "completed"),
        &grok_usage("first", 0, 50),
    );
    let mut monitor = GrokMonitor::new(root.to_path_buf());
    assert_eq!(grok_settle(&mut monitor, now).len(), 1);

    // Nothing changed and nothing was reported: no file is opened.
    for _ in 0..5 {
        assert!(monitor.poll(now).unwrap().is_empty());
        assert_eq!(monitor.bytes_read_last_poll(), 0);
        assert_eq!(monitor.next_poll_deadline(now), None);
    }

    // A session whose ledger has no turn yet; the ledger gets its turn without a report.
    let second = write_grok_session(
        root,
        "second",
        &grok_turn_events("second", 0, "completed"),
        &grok_empty_usage("second"),
    );
    assert!(monitor.note_changes(&changed(&[&second.join("events.jsonl")])));
    assert_eq!(monitor.next_poll_deadline(now), Some(now));
    assert!(grok_settle(&mut monitor, now).is_empty());
    fs::write(
        second.join("usage.json"),
        serde_json::to_vec(&grok_usage("second", 0, 70)).unwrap(),
    )
    .unwrap();
    assert!(poll_grok_n(&mut monitor, now, 3).is_empty());
    assert_eq!(monitor.bytes_read_last_poll(), 0);

    // Reported, the ledger is read and the turn joined.
    assert!(monitor.note_changes(&changed(&[&second.join("usage.json")])));
    let found = grok_settle(&mut monitor, now);
    assert_eq!(
        found
            .iter()
            .map(|turn| turn.output_tokens)
            .collect::<Vec<_>>(),
        [70]
    );

    // Changes outside the watched files or the root are not pending.
    assert!(!monitor.note_changes(&changed(&[
        &second.join("chat_history.jsonl"),
        &temp.path().join("../elsewhere/events.jsonl")
    ])));
}

fn poll_grok_n(monitor: &mut GrokMonitor, now: DateTime<Utc>, count: usize) -> Vec<TurnMetric> {
    let mut found = Vec::new();
    for _ in 0..count {
        found.extend(monitor.poll(now).unwrap());
    }
    found
}

#[test]
fn grok_reconciles_a_snapshot_once_and_discovery_visits_every_session_once() {
    let temp = TestDir::new();
    let root = temp.path();
    let now = time("2026-10-03T10:00:06Z");
    let session = write_grok_session(
        root,
        "only",
        &grok_turn_events("only", 0, "completed"),
        &grok_usage("only", 0, 50),
    );
    let mut monitor = GrokMonitor::new(root.to_path_buf());
    assert_eq!(grok_settle(&mut monitor, now).len(), 1);
    let reconciled = monitor.reconciliations();
    assert!(reconciled >= 1);

    // Idle polls and a report of an unchanged ledger do not join the turns again.
    poll_grok_n(&mut monitor, now, 4);
    assert!(monitor.note_changes(&changed(&[&session.join("usage.json")])));
    assert!(grok_settle(&mut monitor, now).is_empty());
    assert_eq!(monitor.reconciliations(), reconciled);

    // A new session found by discovery is visited once, whatever the report said.
    let late = write_grok_session(
        root,
        "late",
        &grok_turn_events("late", 0, "completed"),
        &grok_usage("late", 0, 60),
    );
    assert!(poll_grok_n(&mut monitor, now + Duration::seconds(10), 3).is_empty());
    assert!(monitor.note_changes(&changed(&[&late.join("usage.json")])));
    let found = grok_settle(&mut monitor, now);
    assert_eq!(
        found
            .iter()
            .map(|turn| turn.output_tokens)
            .collect::<Vec<_>>(),
        [60]
    );
    // The 300 s safety net visits every session once and reads nothing that did not change.
    let after_net = now + Duration::seconds(301);
    let before = monitor.reconciliations();
    assert!(grok_settle(&mut monitor, after_net).is_empty());
    assert_eq!(monitor.reconciliations(), before);
}

#[test]
fn source_monitor_routes_notes_and_deadlines_to_each_source() {
    let temp = TestDir::new();
    let (codex, claude, grok) = (
        temp.path().join("c"),
        temp.path().join("p"),
        temp.path().join("g"),
    );
    for directory in [&codex, &claude, &grok] {
        fs::create_dir_all(directory).unwrap();
    }
    let session = write_grok_session(
        &grok,
        "only",
        &grok_turn_events("only", 0, "completed"),
        &grok_usage("only", 0, 50),
    );
    let now = time("2026-10-03T10:00:06Z");
    let mut sources = SourceMonitor::new(
        codex.clone(),
        claude,
        grok.clone(),
        grok.with_file_name("gemini"),
        grok.with_file_name("opencode"),
    );
    let mut found = Vec::new();
    for _ in 0..10 {
        found.extend(sources.poll(now).unwrap());
    }
    assert_eq!(found.len(), 1);
    assert_eq!(sources.next_poll_deadline(now), None);
    assert_eq!(sources.root_exists("codex"), Some(true));
    assert_eq!(sources.root_exists("unknown"), None);

    // Each path reaches the monitor whose root holds it.
    assert!(sources.note_changes(&changed(&[&session.join("usage.json")])));
    assert_eq!(sources.next_poll_deadline(now), Some(now));
    for _ in 0..3 {
        sources.poll(now).unwrap();
    }
    assert_eq!(sources.next_poll_deadline(now), None);
    assert!(!sources.note_changes(&changed(&[&temp.path().join("other/events.jsonl")])));
    fs::write(codex.join("rollout.jsonl"), b"{}\n").unwrap();
    assert!(sources.note_changes(&changed(&[&codex.join("rollout.jsonl")])));
}

// --- Live responses from Grok turns and the tray reading ---

fn grok_turn(id: &str, at: DateTime<Utc>, response: Option<(i64, f64)>) -> TurnMetric {
    let mut turn = TurnMetric::new_observed(
        id.into(),
        at,
        Some("grok-4".into()),
        1_200,
        20.0,
        None,
        None,
        Some("primary".into()),
        Some("unknown".into()),
        None,
        GROK_CLIENT,
        GROK_PARSER_VERSION,
        GROK_METRIC_VERSION,
    );
    if let Some((tokens, seconds)) = response {
        turn.response_output_tokens = Some(tokens);
        turn.response_duration_seconds = Some(seconds);
        turn.response_count = Some(1);
    }
    turn
}

#[test]
fn a_completed_grok_turn_becomes_a_live_response_only_when_it_qualifies() {
    let at = time("2026-10-03T10:00:00Z");
    let turn = grok_turn("grok-turn", at, Some((900, 12.0)));
    let response = crate::ResponseMetric::from_grok_turn(&turn).unwrap();
    assert_eq!(response.id, "grok-turn");
    assert_eq!(response.completed_at, at);
    assert_eq!(response.model.as_deref(), Some("grok-4"));
    assert_eq!(response.client, GROK_CLIENT);
    assert_eq!(response.source_kind.as_deref(), Some("primary"));
    assert_eq!(
        (response.output_tokens, response.duration_seconds),
        (900, 12.0)
    );
    assert_eq!(response.speed(), 75.0);

    let mut live = crate::LiveResponses::new(at - Duration::minutes(1));
    assert!(live.push(vec![response.clone()], at));
    assert!(!live.push(vec![response], at), "the turn id deduplicates");

    let rejected = |change: &dyn Fn(&mut TurnMetric)| {
        let mut turn = grok_turn("grok-turn", at, Some((900, 12.0)));
        change(&mut turn);
        crate::ResponseMetric::from_grok_turn(&turn).is_none()
    };
    assert!(rejected(&|turn| turn.model = None));
    assert!(rejected(&|turn| turn.source_kind = Some("subagent".into())));
    assert!(rejected(&|turn| turn.source_kind = None));
    assert!(rejected(&|turn| turn.response_output_tokens = Some(199)));
    assert!(rejected(
        &|turn| turn.response_duration_seconds = Some(601.0)
    ));
    assert!(rejected(&|turn| turn.response_duration_seconds = Some(0.1)));
    assert!(rejected(&|turn| turn.response_output_tokens = None));
    assert!(rejected(&|turn| turn.client = crate::CODEX_CLIENT.into()));
    assert!(crate::ResponseMetric::from_grok_turn(&grok_turn("none", at, None)).is_none());
}

fn scoped_turn(
    id: &str,
    at: DateTime<Utc>,
    client: &str,
    model: &str,
    provider: &str,
    response_speed: Option<f64>,
    tokens: i64,
) -> TurnMetric {
    let mut turn = metric(id, at);
    turn.client = client.into();
    turn.model = Some(model.into());
    turn.provider = Some(provider.into());
    turn.output_tokens = tokens;
    turn.turn_throughput_tps = tokens as f64 / 10.0;
    if let Some(speed) = response_speed {
        turn.response_output_tokens = Some((speed * 4.0) as i64);
        turn.response_duration_seconds = Some(4.0);
        turn.response_count = Some(1);
    }
    turn
}

#[test]
fn the_tray_reading_follows_the_dashboard_hero_precedence_and_filters() {
    use crate::{tray_reading, SelectionMode, TrayReadingKind};
    let now = time("2026-10-03T12:00:00Z");
    let minutes_ago = |minutes: i64| now - Duration::minutes(minutes);
    // Newest first.
    let turns = vec![
        scoped_turn(
            "a-new",
            minutes_ago(5),
            CLAUDE_CLIENT,
            "claude-a",
            "anthropic",
            None,
            400,
        ),
        scoped_turn(
            "a-old",
            minutes_ago(30),
            CLAUDE_CLIENT,
            "claude-a",
            "anthropic",
            Some(80.0),
            400,
        ),
        scoped_turn(
            "b",
            minutes_ago(60),
            "codex",
            "gpt-b",
            "openai",
            Some(40.0),
            400,
        ),
        scoped_turn(
            "tiny",
            minutes_ago(90),
            "codex",
            "gpt-c",
            "openai",
            None,
            10,
        ),
        scoped_turn(
            "old",
            now - Duration::days(8),
            "codex",
            "gpt-b",
            "openai",
            Some(10.0),
            400,
        ),
    ];
    let auto = SelectionMode::Auto { tool: None };
    let active = key("claude-a", "anthropic");

    // Live median of the active model first, with the coding tool of its responses.
    let mut stream = crate::LiveResponses::new(minutes_ago(20));
    let mut first = live_for_seconds("claude-a", "claude-code", 0, 600);
    first.completed_at = minutes_ago(2);
    let mut second = first.clone();
    second.id = "second".into();
    second.completed_at = minutes_ago(1);
    second.output_tokens = 1_200;
    second.duration_seconds = 8.0;
    stream.push(vec![first, second], now);
    let reading = tray_reading(&auto, &stream, Some(&active), &turns, None, None, now).unwrap();
    assert_eq!(reading.kind, TrayReadingKind::Live);
    assert_eq!(reading.speed, (50.0 + 150.0) / 2.0);
    assert_eq!(reading.client, CLAUDE_CLIENT);
    assert_eq!(reading.model.as_deref(), Some("claude-a"));
    assert_eq!(reading.provider.as_deref(), Some("anthropic"));

    // No live response: the newest turn of the active model that has response timing, not the
    // newer one without it.
    let empty = crate::LiveResponses::new(minutes_ago(20));
    let reading = tray_reading(&auto, &empty, Some(&active), &turns, None, None, now).unwrap();
    assert_eq!(
        (reading.kind, reading.speed),
        (TrayReadingKind::LatestResponse, 80.0)
    );
    assert_eq!(reading.client, CLAUDE_CLIENT);

    // No active model: the newest turn with response timing leads, within the tool when given.
    let reading = tray_reading(&auto, &empty, None, &turns, None, None, now).unwrap();
    assert_eq!(reading.model.as_deref(), Some("claude-a"));
    let in_codex = SelectionMode::Auto {
        tool: Some("codex".into()),
    };
    let reading = tray_reading(&in_codex, &empty, None, &turns, None, None, now).unwrap();
    assert_eq!(
        (reading.model.as_deref(), reading.speed),
        (Some("gpt-b"), 40.0)
    );
    assert_eq!(reading.client, "codex");
    // An active model of another tool has no records in that tool: nothing to show.
    assert!(tray_reading(&in_codex, &empty, Some(&active), &turns, None, None, now).is_none());

    // A model without response timing falls back to the newest turn long enough for a throughput.
    let timed_out = vec![turns[0].clone(), turns[3].clone()];
    let reading = tray_reading(&auto, &empty, Some(&active), &timed_out, None, None, now).unwrap();
    assert_eq!(
        (reading.kind, reading.speed),
        (TrayReadingKind::TurnFallback, 40.0)
    );
    let tiny = key("gpt-c", "openai");
    assert!(tray_reading(&auto, &empty, Some(&tiny), &timed_out, None, None, now).is_none());

    // The dashboard's tool and provider filters narrow the turns.
    let reading = tray_reading(&auto, &empty, None, &turns, Some("codex"), None, now).unwrap();
    assert_eq!(reading.model.as_deref(), Some("gpt-b"));
    let reading = tray_reading(&auto, &empty, None, &turns, None, Some("openai"), now).unwrap();
    assert_eq!(reading.model.as_deref(), Some("gpt-b"));
    assert!(tray_reading(&auto, &empty, None, &turns, Some("grok-build"), None, now).is_none());

    // A pinned model ignores the live active model; turns older than a week never count.
    let pinned = SelectionMode::parse(r#"model:["gpt-b","openai"]"#).unwrap();
    let reading = tray_reading(&pinned, &empty, Some(&active), &turns, None, None, now).unwrap();
    assert_eq!(
        (reading.model.as_deref(), reading.speed),
        (Some("gpt-b"), 40.0)
    );
    let only_old = vec![turns[4].clone()];
    assert!(tray_reading(&pinned, &empty, None, &only_old, None, None, now).is_none());

    // A pinned cohort reads that exact cohort; one that left the window behaves like Auto.
    let cohort = |turn: &TurnMetric| {
        serde_json::to_string(&json!([
            turn.client,
            turn.client_version,
            turn.parser_version,
            turn.metric_version,
            turn.model,
            turn.provider,
            turn.provider_region,
            turn.reasoning_effort,
            turn.source_kind
        ]))
        .unwrap()
    };
    let pinned_cohort = SelectionMode::parse(&cohort(&turns[2])).unwrap();
    let reading = tray_reading(
        &pinned_cohort,
        &empty,
        Some(&active),
        &turns,
        None,
        None,
        now,
    )
    .unwrap();
    assert_eq!(
        (reading.model.as_deref(), reading.speed),
        (Some("gpt-b"), 40.0)
    );
    let gone = SelectionMode::parse(&cohort(&scoped_turn(
        "x", now, "codex", "gone", "openai", None, 400,
    )))
    .unwrap();
    let reading = tray_reading(&gone, &empty, Some(&active), &turns, None, None, now).unwrap();
    assert_eq!(reading.model.as_deref(), Some("claude-a"));

    // "All" follows the active model without a tool restriction, like the tray always did.
    let reading = tray_reading(
        &SelectionMode::All,
        &empty,
        Some(&active),
        &turns,
        None,
        None,
        now,
    )
    .unwrap();
    assert_eq!(reading.speed, 80.0);
    assert!(tray_reading(&auto, &empty, None, &[], None, None, now).is_none());
}

// --- Launch checkpoints and delegated output already settled ---

fn set_modified(path: &Path, at: DateTime<Utc>) {
    fs::OpenOptions::new()
        .write(true)
        .open(path)
        .unwrap()
        .set_modified(SystemTime::from(at))
        .unwrap();
}

/// A launch from checkpoints skips the unchanged child file but replays a primary file that grew.
/// The replayed old turn is re-emitted without the work in the skipped file, so it must not settle
/// to a lower total than the history already holds.
#[test]
fn a_replayed_turn_keeps_the_delegated_total_settled_before_the_checkpoint() {
    let temp = TestDir::new();
    let sessions = temp.path().join("sessions");
    fs::create_dir_all(&sessions).unwrap();
    let origin = whole_seconds(Utc::now() - Duration::hours(2));
    let at = |seconds: i64| origin + Duration::seconds(seconds);
    let root = sessions.join("rollout-root.jsonl");
    let child = sessions.join("rollout-child.jsonl");
    let mut root_lines = codex_turn_lines(
        primary_codex_meta("root-1"),
        "old-turn",
        &secs(at(0)),
        &secs(at(60)),
        500,
    );
    fs::write(&root, jsonl(&root_lines)).unwrap();
    fs::write(
        &child,
        jsonl(&codex_turn_lines(
            thread_spawn_meta("child-1", Some("root-1"), "root-1"),
            "child-turn",
            &secs(at(20)),
            &secs(at(50)),
            300,
        )),
    )
    .unwrap();
    for path in [&root, &child] {
        set_modified(path, at(180));
    }
    let now = Utc::now() + Duration::hours(1);

    let mut history = History::default();
    let mut first = Monitor::new(sessions.clone());
    history.merge(&settle(&mut first, now), now);
    let old_turn = |history: &History| {
        let found: Vec<_> = history
            .records()
            .iter()
            .filter(|record| record.output_tokens == 500)
            .collect();
        assert_eq!(found.len(), 1);
        found[0].delegated_output_tokens
    };
    assert_eq!(old_turn(&history), Some(300));
    let checkpoints = first.checkpoints().unwrap();
    assert_eq!(checkpoints.len(), 2);

    // The session continues: the primary file grows, the child file does not.
    root_lines = codex_turn_lines(
        primary_codex_meta("root-1"),
        "new-turn",
        &secs(at(900)),
        &secs(at(960)),
        800,
    );
    append_to(&root, &jsonl(&root_lines[1..]));
    set_modified(&root, at(1_000));

    let mut second = Monitor::new(sessions);
    second.set_checkpoints(checkpoints);
    let replayed = settle(&mut second, now);
    assert!(
        replayed
            .iter()
            .all(|record| record.output_tokens != 500 || record.delegated_output_tokens.is_none()),
        "the replayed turn is not finalized from the work this run did not read"
    );
    history.merge(&replayed, now);
    assert_eq!(
        old_turn(&history),
        Some(300),
        "the settled total survives the replay"
    );
    // A turn that started after the skipped file was last modified is unaffected.
    let new_turn = history
        .records()
        .iter()
        .find(|record| record.output_tokens == 800)
        .unwrap();
    assert_eq!(new_turn.delegated_output_tokens, Some(0));
}

/// The same for Claude Code, where the owner of the monitor pair holds the delegation state.
#[test]
fn a_replayed_claude_turn_keeps_the_delegated_total_settled_before_the_checkpoint() {
    let temp = TestDir::new();
    let (codex, claude, grok) = (
        temp.path().join("codex"),
        temp.path().join("claude-projects"),
        temp.path().join("grok-sessions"),
    );
    let project = claude.join("project-a");
    for directory in [&codex, &grok, &project] {
        fs::create_dir_all(directory).unwrap();
    }
    let origin = whole_seconds(Utc::now() - Duration::hours(2));
    let at = |seconds: i64| origin + Duration::seconds(seconds);
    let primary = project.join(format!("{DELEGATION_SESSION}.jsonl"));
    fs::write(
        &primary,
        jsonl(&claude_turn(DELEGATION_SESSION, "old", at(0), at(60), 500)),
    )
    .unwrap();
    let subagent_dir = project.join(DELEGATION_SESSION).join("subagents");
    fs::create_dir_all(&subagent_dir).unwrap();
    let subagent = subagent_dir.join("agent-child.jsonl");
    fs::write(
        &subagent,
        jsonl(&finished_subagent(
            DELEGATION_SESSION,
            "child",
            &secs(at(20)),
            &secs(at(50)),
            300,
        )),
    )
    .unwrap();
    for path in [&primary, &subagent] {
        set_modified(path, at(180));
    }

    // Polls until the monitors need nothing at `now`, following their own deadlines.
    let run = |sources: &mut SourceMonitor, history: &mut History| {
        let mut now = Utc::now() + Duration::hours(1);
        let mut found = Vec::new();
        for _ in 0..60 {
            found.extend(sources.poll(now).unwrap());
            match sources.next_poll_deadline(now) {
                Some(deadline) => now = now.max(deadline),
                None => break,
            }
        }
        history.merge(&found, now);
    };
    let old_turn = |history: &History| {
        let found: Vec<_> = history
            .records()
            .iter()
            .filter(|record| record.output_tokens == 500)
            .collect();
        assert_eq!(found.len(), 1);
        found[0].delegated_output_tokens
    };

    let mut history = History::default();
    let mut first = SourceMonitor::new(
        codex.clone(),
        claude.clone(),
        grok.clone(),
        grok.with_file_name("gemini"),
        grok.with_file_name("opencode"),
    );
    run(&mut first, &mut history);
    assert_eq!(old_turn(&history), Some(300));
    let checkpoints = first.checkpoints(&crate::SourceCheckpoints::default());
    assert_eq!(checkpoints.claude_subagents.len(), 1);

    append_to(
        &primary,
        &jsonl(&claude_turn(
            DELEGATION_SESSION,
            "new",
            at(900),
            at(960),
            800,
        )),
    );
    set_modified(&primary, at(1_000));

    let mut second = SourceMonitor::new(
        codex,
        claude,
        grok.clone(),
        grok.with_file_name("gemini"),
        grok.with_file_name("opencode"),
    );
    second.set_checkpoints(checkpoints);
    run(&mut second, &mut history);
    assert_eq!(old_turn(&history), Some(300));
    let new_turn = history
        .records()
        .iter()
        .find(|record| record.output_tokens == 800)
        .unwrap();
    assert_eq!(new_turn.delegated_output_tokens, Some(0));
}

#[test]
fn history_keeps_a_settled_delegated_total_when_the_same_turn_arrives_without_one() {
    let now = time("2026-10-03T12:00:00Z");
    let mut settled = metric("turn", now - Duration::minutes(10));
    settled.delegated_output_tokens = Some(300);
    let mut provisional = settled.clone();
    provisional.delegated_output_tokens = None;
    provisional.output_tokens = 777;

    let mut history = History::default();
    history.merge(&[settled.clone()], now);
    history.merge(&[provisional.clone()], now);
    assert_eq!(history.records()[0].delegated_output_tokens, Some(300));
    assert_eq!(
        history.records()[0].output_tokens,
        777,
        "the rest is replaced"
    );
    // A final total replaces another, and a turn never settled stays so.
    let mut corrected = settled;
    corrected.delegated_output_tokens = Some(400);
    history.merge(&[corrected], now);
    assert_eq!(history.records()[0].delegated_output_tokens, Some(400));
    let mut fresh = History::default();
    fresh.merge(&[provisional], now);
    assert_eq!(fresh.records()[0].delegated_output_tokens, None);
}

// ---- bounded source reads and ids ------------------------------------------------------------

/// A named pipe: opening it for reading blocks until something writes to it.
#[cfg(unix)]
pub(crate) fn make_fifo(path: &Path) {
    use std::os::unix::ffi::OsStrExt;
    let name = std::ffi::CString::new(path.as_os_str().as_bytes()).unwrap();
    assert_eq!(unsafe { libc::mkfifo(name.as_ptr(), 0o600) }, 0);
}

/// Runs `work` on another thread and fails the test, instead of hanging it, when it blocks.
#[cfg(unix)]
pub(crate) fn within_seconds<T: Send + 'static>(work: impl FnOnce() -> T + Send + 'static) -> T {
    let (sender, receiver) = std::sync::mpsc::channel();
    std::thread::spawn(move || {
        let _ = sender.send(work());
    });
    receiver
        .recv_timeout(StdDuration::from_secs(20))
        .expect("blocked on a file that is not a regular file")
}

#[cfg(unix)]
#[test]
fn only_regular_files_are_opened_for_reading() {
    use crate::reader::open_regular_file;
    use std::os::unix::fs::symlink;
    let temp = TestDir::new();
    let file = temp.path().join("file");
    fs::write(&file, b"data").unwrap();
    let fifo = temp.path().join("fifo");
    make_fifo(&fifo);
    let link_to_file = temp.path().join("link-to-file");
    symlink(&file, &link_to_file).unwrap();
    let link_to_fifo = temp.path().join("link-to-fifo");
    symlink(&fifo, &link_to_fifo).unwrap();
    let directory = temp.path().to_path_buf();

    let results = within_seconds(move || {
        [file, link_to_file, fifo, link_to_fifo, directory]
            .map(|path| open_regular_file(&path).map(|(_, metadata)| metadata.len()))
    });
    // A symlink to a regular file is followed, as everywhere else a source file is stat-ed.
    assert_eq!(results[0].as_ref().unwrap(), &4);
    assert_eq!(results[1].as_ref().unwrap(), &4);
    for refused in &results[2..] {
        assert_eq!(
            refused.as_ref().unwrap_err().kind(),
            std::io::ErrorKind::InvalidInput
        );
    }
    assert_eq!(
        open_regular_file(&temp.path().join("missing"))
            .unwrap_err()
            .kind(),
        std::io::ErrorKind::NotFound
    );
}

#[test]
fn a_capped_read_never_returns_more_than_the_cap_even_if_the_file_grew() {
    use crate::reader::{open_regular_file, read_capped};
    let temp = TestDir::new();
    let path = temp.path().join("file");
    fs::write(&path, vec![b'x'; 10]).unwrap();
    let read = |cap| read_capped(open_regular_file(&path).unwrap().0, cap).unwrap();
    assert_eq!(read(10).unwrap().len(), 10);
    assert_eq!(read(11).unwrap().len(), 10);
    assert!(read(9).is_none());
    assert!(read(0).is_none());
}

#[cfg(unix)]
#[test]
fn grok_never_blocks_on_a_session_file_that_is_a_fifo() {
    let temp = TestDir::new();
    let root = temp.path().to_path_buf();
    let events = grok_turn_events("fifo", 0, "completed");
    let usage = grok_usage("fifo", 0, 50);
    let directory = write_grok_session(&root, "fifo", &events, &usage);
    // A summary pipe is skipped, and the session is still measured without an effort.
    make_fifo(&directory.join("summary.json"));
    let now = time("2026-10-03T10:00:06Z");
    let mut monitor = GrokMonitor::new(root.clone());
    let (monitor, records) = within_seconds(move || {
        let records = monitor.poll(now).unwrap();
        (monitor, records)
    });
    assert_eq!(records.len(), 1);
    assert_eq!(records[0].reasoning_effort, None);

    // Files replaced by pipes after the session was discovered are never opened blocking.
    for name in ["usage.json", "events.jsonl", "summary.json"] {
        let path = directory.join(name);
        let _ = fs::remove_file(&path);
        make_fifo(&path);
    }
    let mut monitor = monitor;
    monitor.note_changes(&changed(&[
        &directory.join("usage.json"),
        &directory.join("events.jsonl"),
        &directory.join("summary.json"),
    ]));
    let records = within_seconds(move || {
        let records = monitor.poll(now + Duration::seconds(1)).unwrap();
        for _ in 0..3 {
            monitor.poll(now + Duration::seconds(2)).unwrap();
        }
        records
    });
    assert!(records.is_empty());
}

#[cfg(unix)]
#[test]
fn a_transcript_replaced_by_a_fifo_does_not_block_the_reader() {
    let temp = TestDir::new();
    let path = temp.path().join("rollout.jsonl");
    fs::write(
        &path,
        jsonl(&[claude_user("2026-10-03T10:00:00Z", "a", json!("go"))]),
    )
    .unwrap();
    let mut reader = crate::reader::IncrementalReader::beginning_claude(path.clone());
    fs::remove_file(&path).unwrap();
    make_fifo(&path);
    let error = within_seconds(move || reader.poll(8_192, time("2026-10-03T10:00:06Z")).err());
    assert_eq!(error.unwrap().kind(), std::io::ErrorKind::InvalidInput);
}

#[test]
fn grok_keeps_only_the_single_model_key_of_a_usage_row() {
    let cases = [
        // A blank key is ignored; the one other key is the model.
        (
            json!({"": {}, "grok-4": {"prompt": "secret"}}),
            Some("grok-4"),
        ),
        (json!({"g".repeat(81): {}}), None),
        (json!({"not a model!": {}}), None),
        (json!({"grok-4": {}, "grok-3": {}}), None),
        (json!(["grok-4"]), None),
        (json!({}), None),
    ];
    for (model_usage, expected) in cases {
        let temp = TestDir::new();
        let mut usage = grok_usage("model", 0, 50);
        usage["turns"][0]["modelUsage"] = model_usage.clone();
        let events = grok_turn_events("model", 0, "completed");
        write_grok_session(temp.path(), "model", &events, &usage);
        let mut monitor = GrokMonitor::new(temp.path().to_path_buf());
        let records = monitor.poll(time("2026-10-03T10:00:06Z")).unwrap();
        assert_eq!(records.len(), 1);
        assert_eq!(records[0].model.as_deref(), expected, "{model_usage}");
    }
}

#[test]
fn ids_from_source_logs_are_kept_only_up_to_512_bytes() {
    let at = "2026-10-03T10:00:00Z";
    let end = "2026-10-03T10:00:01Z";
    let codex = |turn_id: &str| {
        let mut parser = crate::parser::CodexEventParser::new("file".into());
        parser.consume(&event(
            "event_msg",
            json!({ "type": "task_started", "turn_id": turn_id, "started_at": at }),
            at,
        ));
        parser.consume(&event(
            "token_usage_record",
            json!({ "turn_id": turn_id, "turn_token_usage": { "output_tokens": 20 } }),
            at,
        ));
        parser.consume(&event(
            "event_msg",
            json!({ "type": "task_complete", "turn_id": turn_id, "started_at": at,
                    "completed_at": end, "duration_ms": 1000 }),
            end,
        ))
    };
    assert!(codex(&"t".repeat(512)).is_some());
    assert!(codex(&"t".repeat(513)).is_none());

    let claude = |message_id: &str| {
        let mut parser = claude_parser();
        parser.consume_settled(&claude_user(at, "human", json!("go")));
        parser.consume_settled(&assistant_end(end, message_id))
    };
    assert!(claude(&"m".repeat(512)).is_some());
    assert!(claude(&"m".repeat(513)).is_none());

    let grok = |session_id: &str| {
        let temp = TestDir::new();
        let events = grok_turn_events(session_id, 0, "completed");
        write_grok_session(
            temp.path(),
            "session",
            &events,
            &grok_usage(session_id, 0, 50),
        );
        let mut monitor = GrokMonitor::new(temp.path().to_path_buf());
        monitor.poll(time("2026-10-03T10:00:06Z")).unwrap().len()
    };
    assert_eq!(grok(&"s".repeat(512)), 1);
    assert_eq!(grok(&"s".repeat(513)), 0);
}

#[test]
fn the_consent_example_is_the_real_envelope_with_fake_values() {
    let text = crate::example_request_json();
    assert!(text.contains("\n  \"samples\""), "pretty-printed");
    let example: Value = serde_json::from_str(&text).unwrap();
    assert_eq!(example["schemaVersion"], 1);
    assert_eq!(example["sentAt"], "2026-01-01T12:05:00Z");
    let samples = example["samples"].as_array().unwrap();
    assert_eq!(samples.len(), 1);
    let sample = samples[0].as_object().unwrap();

    // Exactly the fields a real sample carries, nothing added and nothing missing.
    let now = time("2026-10-03T12:00:00Z");
    let real = crate::SharedSample::from_metric(&metric("local-id", now), Uuid::new_v4()).unwrap();
    let real = serde_json::to_value(real).unwrap();
    let keys = |object: &serde_json::Map<String, Value>| object.keys().cloned().collect::<Vec<_>>();
    assert_eq!(keys(sample), keys(real.as_object().unwrap()));

    // Obviously fake, allowlisted values; the local id is never part of it.
    assert_eq!(sample["sampleId"], "00000000-0000-4000-8000-000000000000");
    assert_eq!(sample["observedAt"], "2026-01-01T12:00:00Z");
    assert_eq!(sample["model"], "example-model");
    assert_eq!(sample["appVersion"], crate::APP_VERSION);
    assert_eq!(sample["durationMs"], 20_000.0);
    assert_eq!(sample["ttftMs"], 840.0);
    assert_eq!(sample["delegatedOutputTokens"], 0);
    assert_eq!(sample["surface"], "cli");
    assert_eq!(sample["inputTokens"], 48_000);
    assert_eq!(sample["cacheReadInputTokens"], 36_000);
    assert_eq!(sample["cacheWriteInputTokens"], Value::Null);
    assert_eq!(sample["providerRegion"], Value::Null);
    assert!(!text.contains("local-id"));
}

#[test]
fn the_sent_example_of_the_browser_preview_matches_the_real_one() {
    // The dev preview has no shell to ask, so it shows this copy of the example.
    // Regenerate it with `UPDATE_SENT_EXAMPLE=1 cargo test sent_example` after a change.
    let path = Path::new(env!("CARGO_MANIFEST_DIR")).join("../ui/store/sent-example.json");
    let real = crate::example_request_json();
    if std::env::var_os("UPDATE_SENT_EXAMPLE").is_some() {
        fs::write(&path, format!("{real}\n")).unwrap();
    }
    assert_eq!(
        fs::read_to_string(&path).unwrap().trim_end(),
        real,
        "ui/store/sent-example.json is out of date: run `UPDATE_SENT_EXAMPLE=1 cargo test sent_example` in desktop/core"
    );
}

// ---- uploads leave after the sample's five-minute period ------------------------------------------

/// A queue whose delay is `seconds` and that counts how often a delay was drawn.
fn queue_with_jitter(
    seconds: i64,
) -> (SharingQueue, std::sync::Arc<std::sync::atomic::AtomicUsize>) {
    let draws = std::sync::Arc::new(std::sync::atomic::AtomicUsize::new(0));
    let counter = draws.clone();
    let queue = SharingQueue::with_jitter_source(move || {
        counter.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
        Duration::seconds(seconds)
    });
    (queue, draws)
}

#[test]
fn a_sample_is_not_uploaded_before_a_full_period_after_its_own_plus_its_delay() {
    let (mut queue, _) = queue_with_jitter(30);
    queue.enable(time("2026-10-03T09:59:00Z"));
    // Completed in the period 10:00:00 to 10:05:00 and queued at once.
    let completed = time("2026-10-03T10:03:47Z");
    queue.enqueue(&[metric("turn", completed)], completed);
    assert_eq!(queue.len(), 1);
    let eligible = time("2026-10-03T10:10:30Z");
    assert_eq!(queue.next_eligible_after(completed), Some(eligible));
    // Neither the period's own end, the next boundary nor the second before the delay.
    for early in [
        "2026-10-03T10:03:48Z",
        "2026-10-03T10:05:00Z",
        "2026-10-03T10:05:30Z",
        "2026-10-03T10:10:00Z",
        "2026-10-03T10:10:29Z",
    ] {
        assert!(queue.batch(time(early)).is_empty(), "{early}");
    }
    assert_eq!(queue.len(), 1, "waiting samples stay queued");
    assert_eq!(
        queue.next_eligible_after(time("2026-10-03T10:10:29Z")),
        Some(eligible)
    );
    // From the eligible instant on it leaves, and an unacknowledged one is offered again.
    let batch = queue.batch(eligible);
    assert_eq!(batch.len(), 1);
    assert_eq!(batch[0].observed_at, "2026-10-03T10:00:00Z");
    assert_eq!(
        queue.batch(eligible + Duration::seconds(30))[0].sample_id,
        batch[0].sample_id
    );
    assert_eq!(
        queue.next_eligible_after(eligible),
        None,
        "nothing else is waiting"
    );
    queue.ack(&[batch[0].sample_id]);
    assert!(queue.is_empty());
}

#[test]
fn every_normally_settled_turn_of_a_period_leaves_in_the_same_slot() {
    let (mut queue, draws) = queue_with_jitter(17);
    queue.enable(time("2026-10-03T09:59:00Z"));
    let draws_so_far = || draws.load(std::sync::atomic::Ordering::SeqCst);
    // Turns of the period 10:00 to 10:05: one finishing at its start, one in the middle, and two
    // finishing in its last seconds, which are queued only after the period ended (a turn that
    // delegated work settles after 30 s).
    for (id, completed, queued) in [
        ("start", "2026-10-03T10:00:10Z", "2026-10-03T10:00:10Z"),
        ("middle", "2026-10-03T10:02:00Z", "2026-10-03T10:02:30Z"),
        ("late", "2026-10-03T10:04:59Z", "2026-10-03T10:04:59Z"),
        (
            "settled-late",
            "2026-10-03T10:04:55Z",
            "2026-10-03T10:05:25Z",
        ),
    ] {
        queue.enqueue(&[metric(id, time(completed))], time(queued));
    }
    // One in the next period.
    let at = time("2026-10-03T10:07:00Z");
    queue.enqueue(&[metric("next", at)], at);
    assert_eq!(draws_so_far(), 2, "one draw per slot");

    let first_slot = time("2026-10-03T10:10:17Z");
    assert!(queue.batch(first_slot - Duration::seconds(1)).is_empty());
    let batch = queue.batch(first_slot);
    assert_eq!(batch.len(), 4, "the whole period leaves together");
    assert!(batch
        .iter()
        .all(|sample| sample.observed_at == "2026-10-03T10:00:00Z"));
    assert_eq!(
        queue.next_eligible_after(first_slot),
        Some(time("2026-10-03T10:15:17Z"))
    );
    queue.ack(
        &batch
            .iter()
            .map(|sample| sample.sample_id)
            .collect::<Vec<_>>(),
    );
    let later = queue.batch(time("2026-10-03T10:15:17Z"));
    assert_eq!(later.len(), 1);
    assert_eq!(later[0].observed_at, "2026-10-03T10:05:00Z");

    // A sample queued for a slot that already has its delay keeps it.
    let at = time("2026-10-03T10:08:30Z");
    queue.enqueue(&[metric("e", at)], at);
    assert_eq!(draws_so_far(), 2);
}

#[test]
fn a_sample_queued_long_after_its_period_leaves_at_the_next_boundary_plus_the_delay() {
    let (mut queue, draws) = queue_with_jitter(30);
    queue.enable(time("2026-10-03T09:59:00Z"));
    // A primary turn that finished in the period 10:00 to 10:05 is queued half an hour later,
    // once its subagent work is final.
    let completed = time("2026-10-03T10:03:47Z");
    let queued = time("2026-10-03T10:33:47Z");
    queue.enqueue(&[metric("turn", completed)], queued);
    assert_eq!(draws.load(std::sync::atomic::Ordering::SeqCst), 1);
    let eligible = time("2026-10-03T10:35:30Z");
    assert_eq!(queue.next_eligible_after(queued), Some(eligible));
    // Not when its period's own slot would have passed, and not within seconds of being queued.
    for early in [
        "2026-10-03T10:10:30Z",
        "2026-10-03T10:34:17Z",
        "2026-10-03T10:35:00Z",
        "2026-10-03T10:35:29Z",
    ] {
        assert!(queue.batch(time(early)).is_empty(), "{early}");
    }
    let batch = queue.batch(eligible);
    assert_eq!(batch.len(), 1);
    assert_eq!(
        batch[0].observed_at, "2026-10-03T10:00:00Z",
        "the period itself is unchanged"
    );
}

#[test]
fn samples_of_different_periods_queued_in_one_window_share_a_slot_and_its_delay() {
    let (mut queue, draws) = queue_with_jitter(12);
    queue.enable(time("2026-10-03T09:59:00Z"));
    let queued = time("2026-10-03T10:32:10Z");
    queue.enqueue(
        &[
            metric("early", time("2026-10-03T10:02:00Z")),
            metric("later", time("2026-10-03T10:07:00Z")),
            metric("latest", time("2026-10-03T10:11:00Z")),
        ],
        queued,
    );
    assert_eq!(draws.load(std::sync::atomic::Ordering::SeqCst), 1);
    assert_eq!(
        queue.next_eligible_after(queued),
        Some(time("2026-10-03T10:35:12Z"))
    );
    assert!(queue.batch(time("2026-10-03T10:35:11Z")).is_empty());
    let batch = queue.batch(time("2026-10-03T10:35:12Z"));
    let mut periods: Vec<&str> = batch.iter().map(|s| s.observed_at.as_str()).collect();
    periods.sort();
    assert_eq!(
        periods,
        [
            "2026-10-03T10:00:00Z",
            "2026-10-03T10:05:00Z",
            "2026-10-03T10:10:00Z"
        ]
    );
}

#[test]
fn a_sample_queued_exactly_on_a_boundary_takes_that_boundary() {
    let slot_of = |completed: &str, queued: &str| {
        let (mut queue, _) = queue_with_jitter(0);
        queue.enable(time("2026-10-03T09:59:00Z"));
        queue.enqueue(&[metric("turn", time(completed))], time(queued));
        queue
            .next_eligible_after(time("2026-10-03T09:00:00Z"))
            .unwrap()
    };
    let completed = "2026-10-03T10:03:00Z";
    // Queued after the slot of its period: the boundary itself when exactly on it, else the next.
    assert_eq!(
        slot_of(completed, "2026-10-03T10:20:00Z"),
        time("2026-10-03T10:20:00Z")
    );
    assert_eq!(
        slot_of(completed, "2026-10-03T10:19:59Z"),
        time("2026-10-03T10:20:00Z")
    );
    assert_eq!(
        slot_of(completed, "2026-10-03T10:20:01Z"),
        time("2026-10-03T10:25:00Z")
    );
    // Queued exactly when the slot of its period comes, or earlier: that slot, B + 600.
    assert_eq!(
        slot_of(completed, "2026-10-03T10:10:00Z"),
        time("2026-10-03T10:10:00Z")
    );
    assert_eq!(
        slot_of(completed, "2026-10-03T10:05:00Z"),
        time("2026-10-03T10:10:00Z")
    );
    assert_eq!(
        slot_of(completed, "2026-10-03T10:04:00Z"),
        time("2026-10-03T10:10:00Z")
    );
    // A turn finishing 10 s into its period and one 295 s into it, each queued 30 s later.
    assert_eq!(
        slot_of("2026-10-03T10:00:10Z", "2026-10-03T10:00:40Z"),
        time("2026-10-03T10:10:00Z")
    );
    assert_eq!(
        slot_of("2026-10-03T10:04:55Z", "2026-10-03T10:05:25Z"),
        time("2026-10-03T10:10:00Z")
    );

    // A fraction of a second past a boundary belongs to the next slot.
    let (mut queue, _) = queue_with_jitter(0);
    queue.enable(time("2026-10-03T09:59:00Z"));
    let queued = time("2026-10-03T10:20:00Z") + Duration::milliseconds(500);
    queue.enqueue(&[metric("turn", time("2026-10-03T10:03:00Z"))], queued);
    assert_eq!(
        queue.next_eligible_after(time("2026-10-03T09:00:00Z")),
        Some(time("2026-10-03T10:25:00Z"))
    );
}

#[test]
fn more_than_fifty_samples_of_one_period_follow_in_the_next_batch() {
    let (mut queue, _) = queue_with_jitter(0);
    queue.enable(time("2026-10-03T09:59:00Z"));
    let now = time("2026-10-03T10:04:00Z");
    let turns: Vec<TurnMetric> = (0..70)
        .map(|index| metric(format!("turn-{index}"), time("2026-10-03T10:01:00Z")))
        .collect();
    queue.enqueue(&turns, now);
    let eligible = time("2026-10-03T10:10:00Z");
    let first = queue.batch(eligible);
    assert_eq!(first.len(), 50);
    queue.ack(
        &first
            .iter()
            .map(|sample| sample.sample_id)
            .collect::<Vec<_>>(),
    );
    assert_eq!(queue.batch(eligible).len(), 20);
}

#[test]
fn the_upload_delay_is_between_zero_and_sixty_seconds_whatever_the_source_says() {
    for (drawn, expected) in [(-30, 0), (0, 0), (60, 60), (500, 60)] {
        let (mut queue, _) = queue_with_jitter(drawn);
        queue.enable(time("2026-10-03T09:59:00Z"));
        let completed = time("2026-10-03T10:01:00Z");
        queue.enqueue(&[metric("turn", completed)], completed);
        assert_eq!(
            queue.next_eligible_after(completed),
            Some(time("2026-10-03T10:10:00Z") + Duration::seconds(expected)),
            "{drawn}"
        );
    }
}

#[test]
fn the_default_upload_delay_is_random_within_a_minute() {
    let completed = time("2026-10-03T10:01:00Z");
    let slot = time("2026-10-03T10:10:00Z");
    let mut delays = HashSet::new();
    for _ in 0..40 {
        let mut queue = SharingQueue::new();
        queue.enable(time("2026-10-03T09:59:00Z"));
        queue.enqueue(&[metric("turn", completed)], completed);
        let delay = queue.next_eligible_after(completed).unwrap() - slot;
        assert!(
            delay >= Duration::zero() && delay < Duration::seconds(60),
            "{delay}"
        );
        delays.insert(delay.num_milliseconds());
    }
    assert!(delays.len() > 20, "the delay varies between queues");
}

#[test]
fn turning_sharing_off_clears_waiting_samples_and_their_delays() {
    let (mut queue, draws) = queue_with_jitter(10);
    queue.enable(time("2026-10-03T09:59:00Z"));
    let completed = time("2026-10-03T10:01:00Z");
    queue.enqueue(&[metric("turn", completed)], completed);
    assert_eq!(queue.len(), 1);
    queue.disable();
    assert!(queue.is_empty());
    assert_eq!(queue.next_eligible_after(completed), None);
    assert!(queue.batch(time("2026-10-03T11:00:00Z")).is_empty());
    // A new session starts with a new delay for the same period.
    queue.enable(time("2026-10-03T10:00:30Z"));
    queue.enqueue(&[metric("turn-2", completed)], completed);
    assert_eq!(draws.load(std::sync::atomic::Ordering::SeqCst), 2);
}

#[cfg(unix)]
fn mode_of(path: &Path) -> u32 {
    use std::os::unix::fs::PermissionsExt;
    fs::metadata(path).unwrap().permissions().mode() & 0o777
}

#[cfg(unix)]
#[test]
fn app_files_are_written_readable_by_their_owner_only() {
    use std::os::unix::fs::PermissionsExt;
    let temp = TestDir::new();
    let settings = temp.path().join("nested").join("settings.json");
    crate::write_private_file(&settings, b"{\"first\":true}").unwrap();
    assert_eq!(fs::read(&settings).unwrap(), b"{\"first\":true}");
    assert_eq!(mode_of(&settings), 0o600);

    // A file an older version wrote with wider permissions is replaced by a private one.
    fs::set_permissions(&settings, fs::Permissions::from_mode(0o644)).unwrap();
    crate::write_private_file(&settings, b"{\"second\":true}").unwrap();
    assert_eq!(fs::read(&settings).unwrap(), b"{\"second\":true}");
    assert_eq!(mode_of(&settings), 0o600);
    assert_eq!(
        fs::read_dir(settings.parent().unwrap()).unwrap().count(),
        1,
        "no temporary file stays"
    );

    // The local history uses the same writer.
    let history = temp.path().join("history.json");
    History::default().save(&history).unwrap();
    assert_eq!(mode_of(&history), 0o600);
}

#[test]
fn history_that_is_oversized_is_unreadable_and_a_missing_one_is_empty() {
    let temp = TestDir::new();
    let now = time("2026-10-03T12:00:00Z");
    assert!(History::load(temp.path().join("none.json"), now)
        .unwrap()
        .records()
        .is_empty());

    // A file past the 64 MiB cap (sparse, so cheap to make) is not loaded, whatever its stat said
    // when it was opened: the read itself stops one byte past the cap.
    let path = temp.path().join("history.json");
    let file = fs::File::create(&path).unwrap();
    file.set_len(64 * 1024 * 1024 + 1).unwrap();
    drop(file);
    let error = History::load(&path, now).unwrap_err();
    assert_eq!(error.kind(), std::io::ErrorKind::InvalidData);

    // A saved history of normal size loads again.
    let mut history = History::default();
    history.merge(&[metric("turn", now - Duration::minutes(5))], now);
    history.save(&path).unwrap();
    assert_eq!(History::load(&path, now).unwrap().records().len(), 1);
    // A directory is not a history either.
    assert!(History::load(temp.path(), now).is_err());
}

#[cfg(unix)]
#[test]
fn a_history_file_that_is_a_fifo_does_not_block_startup() {
    let temp = TestDir::new();
    let path = temp.path().join("history.json");
    make_fifo(&path);
    let now = time("2026-10-03T12:00:00Z");
    let error = within_seconds(move || History::load(&path, now).unwrap_err());
    assert_eq!(error.kind(), std::io::ErrorKind::InvalidInput);
}

#[test]
fn app_files_are_read_whole_only_when_regular_and_within_the_cap() {
    let temp = TestDir::new();
    let path = temp.path().join("settings.json");
    fs::write(&path, b"0123456789").unwrap();
    assert_eq!(crate::read_private_file(&path, 10).unwrap(), b"0123456789");
    let oversize = crate::read_private_file(&path, 9).unwrap_err();
    assert_eq!(oversize.kind(), std::io::ErrorKind::InvalidData);
    let missing = crate::read_private_file(temp.path().join("none"), 10).unwrap_err();
    assert_eq!(missing.kind(), std::io::ErrorKind::NotFound);
    let folder = crate::read_private_file(temp.path(), 10).unwrap_err();
    assert_eq!(folder.kind(), std::io::ErrorKind::InvalidInput);
    assert_eq!(crate::MAX_SMALL_FILE_BYTES, 1_048_576);
}

#[cfg(unix)]
#[test]
fn an_app_file_that_is_a_pipe_is_refused_without_waiting_for_a_writer() {
    let temp = TestDir::new();
    let path = temp.path().join("settings.json");
    make_fifo(&path);
    let error = within_seconds(move || crate::read_private_file(&path, 1_024).unwrap_err());
    assert_eq!(error.kind(), std::io::ErrorKind::InvalidInput);
}
