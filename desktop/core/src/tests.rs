use crate::parser::JsonlEventParser;
use crate::{
    signed_request, GrokMonitor, History, Monitor, ReportedReasoningEffort, SharingQueue,
    SourceMonitor, TurnMetric, CLAUDE_CLIENT, CLAUDE_METRIC_VERSION, CLAUDE_PARSER_VERSION,
    GROK_CLIENT, GROK_METRIC_VERSION, GROK_PARSER_VERSION, MAX_PENDING_SAMPLES,
};
use chrono::{DateTime, Duration, Utc};
use ed25519_dalek::{Signature, Verifier, VerifyingKey};
use serde_json::{json, Value};
use std::collections::HashSet;
use std::fs;
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

fn time(value: &str) -> DateTime<Utc> {
    DateTime::parse_from_rfc3339(value)
        .unwrap()
        .with_timezone(&Utc)
}

fn metric(id: impl Into<String>, completed_at: DateTime<Utc>) -> TurnMetric {
    TurnMetric::new(
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
    )
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
            "turnNumber":number,
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
    parser.consume(&claude_user(
        start,
        "human-1",
        json!("SYNTHETIC_PROMPT_SENTINEL"),
    ));
    parser.consume(&claude_message(
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
    parser.consume(&claude_user(
        tool,
        "tool-result",
        json!([{"type":"tool_result","content":"SYNTHETIC_TOOL_SENTINEL"}]),
    ));
    // A repeated API message ID is an update to that message's cumulative usage.
    parser.consume(&claude_message(
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
        json!([{"type":"thinking","thinking":"not summed separately"}]),
    );
    let mut value: Value = serde_json::from_slice(&terminal).unwrap();
    value["effort"] = json!("high");
    terminal = serde_json::to_vec(&value).unwrap();
    let result = parser.consume(&terminal).unwrap();
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
    interjection.consume(&user("first", t0));
    interjection.consume(&claude_message(
        "assistant",
        "assistant",
        t1,
        "call-1",
        "claude-model",
        "tool_use",
        2,
        json!([]),
    ));
    interjection.consume(&user("interjection", t1));
    assert!(interjection
        .consume(&claude_message(
            "assistant",
            "assistant",
            t2,
            "call-2",
            "claude-model",
            "end_turn",
            2,
            json!([])
        ))
        .is_none());
    interjection.consume(&user("next-turn", t1));
    assert!(interjection
        .consume(&claude_message(
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
    mixed_model.consume(&user("model-conflict", t0));
    mixed_model.consume(&claude_message(
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
        .consume(&claude_message(
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
    conflict.consume(&user("effort-conflict", t0));
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
    conflict.consume(&high);
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
    let unknown_effort = conflict.consume(&low).unwrap();
    assert_eq!(unknown_effort.reasoning_effort, None);

    let mut sidechain = crate::claude_parser::ClaudeTranscriptParser::new("file".into());
    sidechain.consume(
        &serde_json::to_vec(
            &json!({"type":"assistant","isSidechain":true,"message":{"role":"assistant"}}),
        )
        .unwrap(),
    );
    assert!(!sidechain.excludes_session());
    sidechain.consume(&claude_user(
        t0,
        "primary-after-sidechain",
        json!("synthetic"),
    ));
    assert!(sidechain
        .consume(&claude_message(
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
    missing_primary.consume(&serde_json::to_vec(&user).unwrap());
    assert!(missing_primary
        .consume(&claude_message(
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
    agent.consume(&serde_json::to_vec(&user).unwrap());
    assert!(agent
        .consume(&claude_message(
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
    missing_usage.consume(&claude_user(t0, "missing-usage", json!("x")));
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
    missing_usage.consume(&serde_json::to_vec(&first).unwrap());
    assert!(missing_usage
        .consume(&claude_message(
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
    decreasing.consume(&claude_user(t0, "decreasing-usage", json!("x")));
    decreasing.consume(&claude_message(
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
        .consume(&claude_message(
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
    modelless.consume(&claude_user(t0, "modelless", json!("x")));
    let unknown = modelless
        .consume(&claude_message(
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

#[test]
fn grok_matches_completed_event_to_usage_snapshot_and_replaces_updated_turn() {
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
    assert_eq!(first.metric_version, GROK_METRIC_VERSION);
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
    assert_eq!(updated.len(), 1);
    assert_eq!(updated[0].id, first.id);
    assert_eq!(updated[0].output_tokens, 90);
    history.merge(&updated, now + Duration::seconds(1));
    assert_eq!(
        history.records().len(),
        1,
        "usage snapshots replace the same turn"
    );
    assert_eq!(history.records()[0].output_tokens, 90);
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
                "turnNumber":1,"endedAt":"2026-10-03T10:00:05Z","outputTokens":20,
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
                {"turnNumber":5,"endedAt":"2026-10-03T10:00:05Z","outputTokens":20,"usageIsIncomplete":false},
                {"turnNumber":5,"endedAt":"2026-10-03T10:00:05Z","outputTokens":21,"usageIsIncomplete":false}
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
    let completion = event(
        "event_msg",
        json!({ "type": "task_complete", "turn_id": "turn", "started_at": started, "completed_at": completed, "duration_ms": 1000 }),
        &completed,
    );
    let mut contents = jsonl(&[header, usage]);
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
fn monitor_rotates_caught_up_live_tails_so_older_open_sessions_are_serviced() {
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

    // Keep the writer open, as Codex does. Holding `now` constant prevents periodic
    // discovery from making this old session appear recent and masking starvation.
    let old_path = temp.path().join("session-00.jsonl");
    let start = (base - Duration::seconds(2)).to_rfc3339_opts(chrono::SecondsFormat::Secs, true);
    let completed =
        (base - Duration::seconds(1)).to_rfc3339_opts(chrono::SecondsFormat::Secs, true);
    let mut append = fs::OpenOptions::new().append(true).open(old_path).unwrap();
    append
        .write_all(&jsonl(&[
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

    let mut found = false;
    for _ in 0..6 {
        let records = monitor.poll(base).unwrap();
        assert!(monitor.bytes_read_last_poll() <= Monitor::MAX_POLL_BYTES);
        if records.iter().any(|record| record.output_tokens == 987) {
            found = true;
            break;
        }
    }
    assert!(
        found,
        "older caught-up live tails must rotate into the poll lane"
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
        after_truncate = monitor.poll(base + Duration::seconds(40 + index)).unwrap();
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
    let mut monitor = SourceMonitor::new(codex, claude, grok);
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
    let first = queue.batch(now + Duration::seconds(3));
    let retry = queue.batch(now + Duration::seconds(3));
    assert_eq!(first[0].sample_id, retry[0].sample_id);
    assert_eq!(first[0].app_version, "0.1.9");
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
    let claude = TurnMetric::new_observed(
        "local-claude-digest".into(),
        completed,
        Some("claude-opus-4-1".into()),
        120,
        6.0,
        Some("1.2.3".into()),
        None,
        Some("primary".into()),
        Some("unknown".into()),
        Some("high".into()),
        CLAUDE_CLIENT,
        CLAUDE_PARSER_VERSION,
        CLAUDE_METRIC_VERSION,
    );
    let grok = TurnMetric::new_observed(
        "local-grok-digest".into(),
        completed,
        Some("grok-4".into()),
        240,
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
                .join("tests/fixtures/rust-signed-request-v0.1.9-mixed.json"),
            serde_json::to_vec_pretty(&packet).unwrap(),
        )
        .unwrap();
        return;
    }
    let actual: Value = serde_json::from_slice(&request.body).unwrap();
    let packet: Value = serde_json::from_str(include_str!(
        "../tests/fixtures/rust-signed-request-v0.1.9-mixed.json"
    ))
    .unwrap();
    assert_eq!(
        String::from_utf8(request.body.clone()).unwrap(),
        packet["rawBody"]
    );
    assert_eq!(request.public_key, packet["publicKey"]);
    assert_eq!(request.signature, packet["signature"]);
    assert_eq!(actual["samples"].as_array().unwrap().len(), 2);
    assert_eq!(actual["samples"][0]["client"], "claude-code");
    assert_eq!(actual["samples"][0]["provider"], "unknown");
    assert_eq!(actual["samples"][0]["ttftMs"], Value::Null);
    assert_eq!(actual["samples"][1]["client"], "grok-build");
    assert_eq!(actual["samples"][1]["clientVersion"], "unknown");
    assert_eq!(actual["samples"][1]["ttftMs"], Value::Null);
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
