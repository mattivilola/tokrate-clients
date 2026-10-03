use crate::{
    signed_request, History, Monitor, ReportedReasoningEffort, SharingQueue, TurnMetric,
    MAX_PENDING_SAMPLES,
};
use chrono::{DateTime, Duration, Utc};
use ed25519_dalek::{Signature, Verifier, VerifyingKey};
use serde_json::{json, Value};
use std::fs;
use std::io::Write;
use std::path::{Path, PathBuf};
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

fn assert_json_compatible(actual: &Value, expected: &Value) {
    match (actual, expected) {
        (Value::Number(left), Value::Number(right)) => {
            assert_eq!(left.as_f64(), right.as_f64());
        }
        (Value::Array(left), Value::Array(right)) => {
            assert_eq!(left.len(), right.len());
            for (left, right) in left.iter().zip(right) {
                assert_json_compatible(left, right);
            }
        }
        (Value::Object(left), Value::Object(right)) => {
            assert_eq!(
                left.keys().collect::<Vec<_>>(),
                right.keys().collect::<Vec<_>>()
            );
            for key in left.keys() {
                assert_json_compatible(&left[key], &right[key]);
            }
        }
        _ => assert_eq!(actual, expected),
    }
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
    assert_eq!(first[0].app_version, "0.1.8");
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
fn signed_json_matches_swift_fixture_and_signature_verifies_over_exact_bytes() {
    let completed = time("2026-10-03T10:03:47Z");
    let mut source = metric("local-only-digest", completed);
    source.model = Some("gpt-6-astra".into());
    source.reasoning_effort = Some("high".into());
    let sample = crate::SharedSample::from_metric(
        &source,
        Uuid::parse_str("00000000-0000-4000-8000-000000000001").unwrap(),
    )
    .unwrap();
    let now = time("2026-10-03T10:05:00Z");
    let key = [7_u8; 32];
    let request = signed_request(&[sample], &key, now).unwrap();
    let actual: Value = serde_json::from_slice(&request.body).unwrap();
    let expected: Value = serde_json::from_str(include_str!(
        "../tests/fixtures/swift-compatible-sample-v1.json"
    ))
    .unwrap();
    let packet: Value = serde_json::from_str(include_str!(
        "../tests/fixtures/rust-signed-request-v0.1.8.json"
    ))
    .unwrap();
    assert_json_compatible(&actual, &expected);
    assert_eq!(
        String::from_utf8(request.body.clone()).unwrap(),
        packet["rawBody"]
    );
    assert_eq!(request.public_key, packet["publicKey"]);
    assert_eq!(request.signature, packet["signature"]);
    assert!(!request
        .body
        .windows(b"local-only-digest".len())
        .any(|window| window == b"local-only-digest"));

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
