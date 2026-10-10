//! Tests for the request outcomes (contract "Request outcomes (0.1.22)"): the Claude Code and Codex
//! classification over records shaped like the real ones (error texts redacted), the monitors that
//! carry the outcomes, the aggregator behind the sharing queue and the version 2 upload envelope.
//! The OpenCode and Kimi Code parsers are tested beside their other tests.

use crate::claude_parser::ClaudeTranscriptParser;
use crate::parser::{CodexEventParser, JsonlEventParser};
use crate::{
    signed_request, RequestOutcome, RequestOutcomeKind, SharedRequestCount, SharedSample,
    SharingQueue, SourceMonitor, TurnMetric, CLAUDE_CLIENT, CLAUDE_PARSER_VERSION, CODEX_CLIENT,
    CODEX_PARSER_VERSION, KIMI_CLIENT, KIMI_PARSER_VERSION, MAX_PENDING_REQUEST_COUNTS,
    OPENCODE_CLIENT, OPENCODE_PARSER_VERSION,
};
use chrono::{DateTime, Duration, Utc};
use serde_json::{json, Value};
use std::collections::HashSet;
use std::fs;
use std::path::Path;
use std::time::SystemTime;
use tempfile::TempDir;
use uuid::Uuid;

use RequestOutcomeKind::{Overloaded, ServerError, Succeeded};

fn time(value: &str) -> DateTime<Utc> {
    DateTime::parse_from_rfc3339(value)
        .unwrap()
        .with_timezone(&Utc)
}

fn jsonl(lines: &[Vec<u8>]) -> Vec<u8> {
    let mut output = Vec::new();
    for line in lines {
        output.extend_from_slice(line);
        output.push(b'\n');
    }
    output
}

/// What a parser reported, without the local key and time: kind, model and provider.
fn shape(outcomes: &[RequestOutcome]) -> Vec<(RequestOutcomeKind, &str, &str)> {
    outcomes
        .iter()
        .map(|outcome| {
            (
                outcome.kind,
                outcome.model.as_str(),
                outcome.provider.as_str(),
            )
        })
        .collect()
}

// ---- Claude Code --------------------------------------------------------------------------------

const SESSION: &str = "5a1c0d0e-0000-4000-8000-000000000001";
const MODEL: &str = "claude-opus-5-5";

fn message_id(n: u32) -> String {
    format!("msg_01{n:0>22}")
}

fn request_id(n: u32) -> String {
    format!("req_{n:0>24}")
}

/// A real first-party assistant response of `tokens` output tokens.
fn real(at: &str, n: u32, tokens: i64) -> Vec<u8> {
    serde_json::to_vec(&json!({
        "type": "assistant", "uuid": format!("real-{n}"), "timestamp": at,
        "sessionId": SESSION, "isSidechain": false, "userType": "external",
        "version": "2.1.295", "requestId": request_id(n),
        "message": {"id": message_id(n), "model": MODEL, "role": "assistant",
            "stop_reason": "end_turn", "content": [{"type": "text", "text": "done"}],
            "usage": {"output_tokens": tokens}}
    }))
    .unwrap()
}

/// A real response on Amazon Bedrock (its own message id prefix).
fn bedrock(at: &str, n: u32) -> Vec<u8> {
    serde_json::to_vec(&json!({
        "type": "assistant", "uuid": format!("bedrock-{n}"), "timestamp": at,
        "sessionId": SESSION, "isSidechain": false, "userType": "external",
        "version": "2.1.295",
        "message": {"id": format!("msg_bdrk_01{n:0>22}"),
            "model": "eu.anthropic.claude-sonnet-4-5-20250929-v1:0", "role": "assistant",
            "stop_reason": "end_turn", "content": [{"type": "text", "text": "done"}],
            "usage": {"output_tokens": 50}}
    }))
    .unwrap()
}

/// The synthetic record Claude Code writes when a request finally fails. `text` is the (redacted)
/// error text; `secret` marks text the tests must never see again.
fn api_error(at: &str, uuid: &str, error: &str, status: Option<i64>, text: &str) -> Vec<u8> {
    let mut record = json!({
        "type": "assistant", "uuid": uuid, "timestamp": at,
        "sessionId": SESSION, "isSidechain": false, "userType": "external",
        "version": "2.1.295", "isApiErrorMessage": true, "error": error,
        "message": {"id": format!("{uuid}-message"), "model": "<synthetic>",
            "role": "assistant", "stop_reason": "stop_sequence", "stop_sequence": "",
            "content": [{"type": "text", "text": text}],
            "usage": {"input_tokens": 0, "output_tokens": 0}}
    });
    if let Some(status) = status {
        record["apiErrorStatus"] = json!(status);
    }
    serde_json::to_vec(&record).unwrap()
}

fn claude_outcomes(lines: &[Vec<u8>]) -> Vec<RequestOutcome> {
    let mut parser = ClaudeTranscriptParser::new("file".into());
    for line in lines {
        parser.consume(line);
    }
    parser.flush_pending(DateTime::<Utc>::MAX_UTC, true);
    parser.take_outcomes()
}

/// The failures (not the successes) a real response followed by `failure` leads to.
fn claude_failure(failure: Vec<u8>) -> Vec<(RequestOutcomeKind, String, String)> {
    claude_outcomes(&[real("2026-10-09T12:00:00Z", 1, 400), failure])
        .into_iter()
        .filter(|outcome| outcome.kind != Succeeded)
        .map(|outcome| (outcome.kind, outcome.model, outcome.provider))
        .collect()
}

#[test]
fn claude_overload_and_server_errors_are_attributed_to_the_previous_real_response() {
    let at = "2026-10-09T12:01:00Z";
    let model = || MODEL.to_owned();
    let provider = || "anthropic".to_owned();
    // 529 is an overload, any other 5xx a server error (whatever the enum says).
    assert_eq!(
        claude_failure(api_error(
            at,
            "e1",
            "server_error",
            Some(529),
            "API Error: Repeated 529 Overloaded errors."
        )),
        [(Overloaded, model(), provider())]
    );
    assert_eq!(
        claude_failure(api_error(
            at,
            "e2",
            "server_error",
            Some(500),
            "API Error: 500 internal"
        )),
        [(ServerError, model(), provider())]
    );
    assert_eq!(
        claude_failure(api_error(
            at,
            "e3",
            "server_error",
            Some(503),
            "unavailable"
        )),
        [(ServerError, model(), provider())]
    );
    // The fixed text prefixes and fragments, with no status.
    assert_eq!(
        claude_failure(api_error(
            at,
            "e4",
            "server_error",
            None,
            "API Error: Repeated 529 Overloaded errors. The API is at capacity"
        )),
        [(Overloaded, model(), provider())]
    );
    assert_eq!(
        claude_failure(api_error(
            at,
            "e5",
            "rate_limit",
            None,
            "Opus is experiencing high load, please use /model to switch to Sonnet"
        )),
        [(Overloaded, model(), provider())]
    );
    assert_eq!(
        claude_failure(api_error(
            at,
            "e6",
            "rate_limit",
            Some(429),
            "API Error: Server is temporarily limiting requests (not your usage limit)"
        )),
        [(Overloaded, model(), provider())]
    );
    // A 5xx that ends a response mid-stream.
    assert_eq!(
        claude_failure(api_error(
            at,
            "e7",
            "server_error",
            None,
            "API Error: Server error mid-response. The response above may be incomplete."
        )),
        [(ServerError, model(), provider())]
    );
}

#[test]
fn claude_failures_that_are_not_the_providers_are_dropped() {
    let at = "2026-10-09T12:01:00Z";
    for (name, record) in [
        (
            "session limit",
            api_error(
                at,
                "x1",
                "rate_limit",
                Some(429),
                "You've hit your session limit · resets 9:30pm",
            ),
        ),
        (
            "request rejected 429",
            api_error(
                at,
                "x2",
                "rate_limit",
                Some(429),
                "API Error: Request rejected (429)",
            ),
        ),
        (
            "authentication",
            api_error(
                at,
                "x3",
                "authentication_failed",
                Some(401),
                "Invalid API key · Please run /login",
            ),
        ),
        (
            "invalid request",
            api_error(at, "x4", "invalid_request", Some(400), "Prompt is too long"),
        ),
        (
            "connection lost",
            api_error(
                at,
                "x5",
                "server_error",
                None,
                "API Error: Connection to the API was lost (ECONNRESET).",
            ),
        ),
        (
            "timeout",
            api_error(at, "x6", "server_error", None, "Request timed out"),
        ),
        (
            "stream dropped mid-response",
            api_error(
                at,
                "x7",
                "server_error",
                None,
                "API Error: Connection lost mid-response.",
            ),
        ),
        (
            "model not found",
            api_error(at, "x8", "model_not_found", Some(404), "model not found"),
        ),
        (
            "unknown",
            api_error(at, "x9", "unknown", None, "something else"),
        ),
        // Not a synthetic API-error record at all, whatever its status or text says.
        ("a normal record", {
            let mut record: Value = serde_json::from_slice(&api_error(
                at,
                "x10",
                "server_error",
                Some(500),
                "API Error: 500",
            ))
            .unwrap();
            record["isApiErrorMessage"] = json!(false);
            serde_json::to_vec(&record).unwrap()
        }),
    ] {
        assert!(claude_failure(record).is_empty(), "{name}");
    }
}

#[test]
fn a_claude_failure_without_an_earlier_real_response_has_no_model_and_is_dropped() {
    let failure = api_error(
        "2026-10-09T12:00:00Z",
        "first",
        "server_error",
        Some(529),
        "overloaded",
    );
    assert!(claude_outcomes(&[failure.clone()]).is_empty());
    // A later failure uses the response read since.
    let outcomes = claude_outcomes(&[failure, real("2026-10-09T12:00:30Z", 2, 90)]);
    assert_eq!(shape(&outcomes), [(Succeeded, MODEL, "anthropic")]);
}

#[test]
fn claude_retries_are_never_counted() {
    let retry = |attempt: u32, status: i64| {
        serde_json::to_vec(&json!({
            "type": "system", "subtype": "api_error", "level": "error",
            "timestamp": "2026-10-09T12:00:10Z", "uuid": format!("retry-{attempt}"),
            "sessionId": SESSION, "isSidechain": false, "userType": "external",
            "version": "2.1.295", "retryAttempt": attempt, "maxRetries": 10, "retryInMs": 552,
            "source": "request_retry",
            "error": {"status": status, "message": "Overloaded", "formatted": "529"}
        }))
        .unwrap()
    };
    let outcomes = claude_outcomes(&[
        real("2026-10-09T12:00:00Z", 1, 400),
        retry(1, 529),
        retry(2, 529),
        retry(3, 500),
        real("2026-10-09T12:00:20Z", 2, 400),
    ]);
    // Only the two real responses; the three retried failures are nothing.
    assert_eq!(shape(&outcomes), [(Succeeded, MODEL, "anthropic"); 2]);
}

#[test]
fn claude_successes_count_before_the_response_speed_filter() {
    // A tool-call-only response, a short one and a long one (over 600 s) all succeeded.
    let outcomes = claude_outcomes(&[
        real("2026-10-09T12:00:00Z", 1, 3),
        real("2026-10-09T12:00:02Z", 2, 40),
        real("2026-10-09T12:00:04Z", 3, 6_000),
    ]);
    assert_eq!(shape(&outcomes), [(Succeeded, MODEL, "anthropic"); 3]);
    assert_eq!(outcomes[0].occurred_at, time("2026-10-09T12:00:00Z"));
    assert_eq!(outcomes[0].client, CLAUDE_CLIENT);
    assert_eq!(outcomes[0].parser_version, CLAUDE_PARSER_VERSION);
    assert_eq!(outcomes[0].client_version.as_deref(), Some("2.1.295"));
    // Records of one response (a thinking block and its text) are one request.
    let split = claude_outcomes(&[
        real("2026-10-09T12:00:00Z", 1, 3),
        real("2026-10-09T12:00:01Z", 1, 9),
    ]);
    assert_eq!(split.len(), 1);
    // Reading the same records again names the same request.
    assert_eq!(
        claude_outcomes(&[real("2026-10-09T12:00:00Z", 1, 3)])[0].dedupe_key,
        split[0].dedupe_key
    );
    // A synthetic message, an id that is no `msg_` id and a model that is unsafe are not
    // responses of a known model.
    let mut foreign =
        serde_json::from_slice::<Value>(&real("2026-10-09T12:00:00Z", 4, 10)).unwrap();
    foreign["message"]["id"] = json!("not-an-api-message-id");
    let mut unsafe_model =
        serde_json::from_slice::<Value>(&real("2026-10-09T12:00:01Z", 5, 10)).unwrap();
    unsafe_model["message"]["model"] = json!("model with spaces");
    assert!(claude_outcomes(&[
        serde_json::to_vec(&foreign).unwrap(),
        serde_json::to_vec(&unsafe_model).unwrap(),
        api_error("2026-10-09T12:00:02Z", "s", "unknown", None, "x"),
    ])
    .is_empty());
}

#[test]
fn claude_provider_comes_from_the_response_evidence_and_unknown_routes_are_dropped() {
    let outcomes = claude_outcomes(&[bedrock("2026-10-09T12:00:00Z", 1)]);
    assert_eq!(
        shape(&outcomes),
        [(Succeeded, "claude-sonnet-4-5-20250929", "amazon-bedrock")]
    );
    // A response without provider evidence (a bare `msg_01` id from a proxy) names no provider:
    // neither it nor a failure after it is an outcome.
    let mut proxy = serde_json::from_slice::<Value>(&real("2026-10-09T12:00:00Z", 2, 10)).unwrap();
    proxy.as_object_mut().unwrap().remove("requestId");
    assert!(claude_outcomes(&[
        serde_json::to_vec(&proxy).unwrap(),
        api_error(
            "2026-10-09T12:00:05Z",
            "after-proxy",
            "server_error",
            Some(500),
            "x"
        ),
    ])
    .is_empty());
}

#[test]
fn a_claude_mid_stream_failure_counts_the_partial_response_and_the_failure() {
    let outcomes = claude_outcomes(&[
        real("2026-10-09T12:00:00Z", 1, 200),
        api_error(
            "2026-10-09T12:00:05Z",
            "mid",
            "server_error",
            None,
            "API Error: Server error mid-response. The response above may be incomplete.",
        ),
    ]);
    assert_eq!(
        shape(&outcomes),
        [
            (Succeeded, MODEL, "anthropic"),
            (ServerError, MODEL, "anthropic")
        ]
    );
    assert_eq!(outcomes[1].occurred_at, time("2026-10-09T12:00:05Z"));
}

#[test]
fn a_claude_subagent_failure_uses_the_responses_of_its_own_file() {
    let as_agent = |line: Vec<u8>| {
        let mut value: Value = serde_json::from_slice(&line).unwrap();
        value["isSidechain"] = json!(true);
        value["agentId"] = json!("a1b2c3");
        serde_json::to_vec(&value).unwrap()
    };
    let mut parser = ClaudeTranscriptParser::new_subagent("agent-file".into());
    parser.consume(&as_agent(real("2026-10-09T12:00:00Z", 7, 90)));
    parser.consume(&as_agent(api_error(
        "2026-10-09T12:00:02Z",
        "sub",
        "server_error",
        Some(502),
        "bad gateway",
    )));
    // A primary record is not a record of the subagent file.
    parser.consume(&api_error(
        "2026-10-09T12:00:03Z",
        "main-agent",
        "server_error",
        Some(502),
        "bad gateway",
    ));
    let outcomes = parser.take_outcomes();
    assert_eq!(
        shape(&outcomes),
        [
            (Succeeded, MODEL, "anthropic"),
            (ServerError, MODEL, "anthropic")
        ]
    );
}

#[test]
fn error_text_never_reaches_an_outcome() {
    // An outcome has no text field; the debug form of one read from a record whose text and
    // model carry a marker must not contain it.
    let secret = "SECRET-ERROR-TEXT-do-not-keep";
    let outcomes = claude_outcomes(&[
        real("2026-10-09T12:00:00Z", 1, 400),
        api_error(
            "2026-10-09T12:00:01Z",
            "leak",
            "rate_limit",
            None,
            &format!("{secret} Opus is experiencing high load"),
        ),
    ]);
    assert_eq!(outcomes.len(), 2);
    assert!(!format!("{outcomes:?}").contains(secret));
}

// ---- Codex --------------------------------------------------------------------------------------

fn codex_line(kind: &str, payload: Value, at: &str) -> Vec<u8> {
    serde_json::to_vec(&json!({"timestamp": at, "type": kind, "payload": payload})).unwrap()
}

fn session_meta(version: Option<&str>, provider: &str) -> Vec<u8> {
    let mut payload = json!({
        "id": "0199aaaa-0000-7000-8000-000000000001", "originator": "codex_cli_rs",
        "source": "cli", "model_provider": provider
    });
    if let Some(version) = version {
        payload["cli_version"] = json!(version);
    }
    codex_line("session_meta", payload, "2026-10-09T12:00:00Z")
}

fn turn_context(turn: &str, model: &str) -> Vec<u8> {
    codex_line(
        "turn_context",
        json!({"turn_id": turn, "model": model, "effort": "high"}),
        "2026-10-09T12:00:01Z",
    )
}

fn task_started(turn: &str) -> Vec<u8> {
    codex_line(
        "event_msg",
        json!({"type": "task_started", "turn_id": turn, "started_at": "2026-10-09T12:00:01Z"}),
        "2026-10-09T12:00:01Z",
    )
}

fn usage_record(turn: &str, response: &str, at: &str, tokens: i64) -> Vec<u8> {
    codex_line(
        "token_usage_record",
        json!({"turn_id": turn, "response_id": response, "usage": {"output_tokens": tokens},
            "turn_token_usage": {"output_tokens": tokens}}),
        at,
    )
}

fn task_complete(turn: &str, at: &str, error: Option<Value>) -> Vec<u8> {
    let mut payload = json!({"type": "task_complete", "turn_id": turn,
        "started_at": "2026-10-09T12:00:01Z", "completed_at": at, "duration_ms": 4000});
    if let Some(error) = error {
        payload["error"] = error;
    }
    codex_line("event_msg", payload, at)
}

fn codex_outcomes(lines: &[Vec<u8>]) -> Vec<RequestOutcome> {
    let mut parser = CodexEventParser::new("file".into());
    for line in lines {
        parser.consume(line);
    }
    parser.take_outcomes()
}

/// A rollout of version `version` on `provider` whose only turn ended with `info`.
fn codex_failure(
    version: Option<&str>,
    provider: &str,
    info: Value,
) -> Vec<(RequestOutcomeKind, String, String)> {
    codex_outcomes(&[
        session_meta(version, provider),
        turn_context("t1", "gpt-5"),
        task_started("t1"),
        task_complete(
            "t1",
            "2026-10-09T12:00:05Z",
            Some(json!({"message": "SECRET raw provider text", "codex_error_info": info})),
        ),
    ])
    .into_iter()
    .map(|outcome| (outcome.kind, outcome.model, outcome.provider))
    .collect()
}

#[test]
fn codex_failures_follow_the_error_enum_and_status() {
    let openai = |kind| (kind, "gpt-5".to_owned(), "openai".to_owned());
    let failure = |info: Value| codex_failure(Some("0.159.2"), "openai", info);
    assert_eq!(failure(json!("server_overloaded")), [openai(Overloaded)]);
    assert_eq!(
        failure(json!("internal_server_error")),
        [openai(ServerError)]
    );
    for variant in [
        "http_connection_failed",
        "response_too_many_failed_attempts",
        "response_stream_connection_failed",
    ] {
        assert_eq!(
            failure(json!({variant: {"http_status_code": 503}})),
            [openai(ServerError)],
            "{variant} 503"
        );
        assert_eq!(
            failure(json!({variant: {"http_status_code": 500}})),
            [openai(ServerError)],
            "{variant} 500"
        );
        // HTTP 529 is an overload wherever it is reported.
        assert_eq!(
            failure(json!({variant: {"http_status_code": 529}})),
            [openai(Overloaded)],
            "{variant} 529"
        );
        for status in [json!(403), json!(401), json!(429), json!(400), Value::Null] {
            assert!(
                failure(json!({variant: {"http_status_code": status}})).is_empty(),
                "{variant} {status}"
            );
        }
    }
    // Everything else is the user's side, ambiguous or not a failure of the provider.
    for info in [
        json!("usage_limit_exceeded"),
        json!("rate_limit_exceeded"),
        json!("unauthorized"),
        json!("bad_request"),
        json!("context_window_exceeded"),
        json!("other"),
        json!("a_variant_of_a_newer_version"),
        json!({"response_stream_disconnected": {"http_status_code": 503}}),
        json!({"unknown_variant": {"http_status_code": 503}}),
        Value::Null,
    ] {
        assert!(failure(info.clone()).is_empty(), "{info}");
    }
    // A completion without an error is no failure.
    assert!(codex_outcomes(&[
        session_meta(Some("0.159.2"), "openai"),
        turn_context("t1", "gpt-5"),
        task_started("t1"),
        task_complete("t1", "2026-10-09T12:00:05Z", None),
    ])
    .is_empty());
}

#[test]
fn codex_failures_are_dated_by_the_completion_and_keyed_by_their_turn() {
    let lines = [
        session_meta(Some("0.159.2"), "openai"),
        turn_context("t1", "gpt-5"),
        task_started("t1"),
        task_complete(
            "t1",
            "2026-10-09T12:00:05Z",
            Some(json!({"message": "x", "codex_error_info": "server_overloaded"})),
        ),
    ];
    let first = codex_outcomes(&lines);
    assert_eq!(first.len(), 1);
    assert_eq!(first[0].occurred_at, time("2026-10-09T12:00:05Z"));
    assert_eq!(first[0].client, CODEX_CLIENT);
    assert_eq!(first[0].parser_version, CODEX_PARSER_VERSION);
    assert_eq!(first[0].client_version.as_deref(), Some("0.159.2"));
    // Read again by another parser, it is the same outcome.
    assert_eq!(codex_outcomes(&lines)[0].dedupe_key, first[0].dedupe_key);
}

#[test]
fn codex_older_than_0_145_unknown_versions_and_other_providers_report_nothing() {
    let overloaded = json!("server_overloaded");
    for version in [
        Some("0.144.5"),
        Some("0.86.0"),
        Some("0.145.0-alpha.3"),
        Some("0.145"),
        Some("not-a-version"),
        None,
    ] {
        assert!(
            codex_failure(version, "openai", overloaded.clone()).is_empty(),
            "{version:?}"
        );
    }
    for version in [
        "0.145.0",
        "0.145.1",
        "0.146.0-alpha.1",
        "0.145.0+build5",
        "1.0.0",
    ] {
        assert_eq!(
            codex_failure(Some(version), "openai", overloaded.clone()).len(),
            1,
            "{version}"
        );
    }
    // Azure, Ollama and other providers are not OpenAI's service.
    assert!(codex_failure(Some("0.159.2"), "azure", overloaded.clone()).is_empty());
    assert!(codex_failure(Some("0.159.2"), "ollama", overloaded).is_empty());
}

#[test]
fn codex_successes_are_distinct_token_usage_records_including_short_ones() {
    let rollout = |version: Option<&str>, provider: &str| {
        codex_outcomes(&[
            session_meta(version, provider),
            turn_context("t1", "gpt-5"),
            task_started("t1"),
            usage_record("t1", "resp_1", "2026-10-09T12:00:02Z", 12),
            usage_record("t1", "resp_2", "2026-10-09T12:00:03Z", 4_000),
            // The same response again is the same request.
            usage_record("t1", "resp_2", "2026-10-09T12:00:03Z", 4_000),
        ])
    };
    let outcomes = rollout(Some("0.159.2"), "openai");
    assert_eq!(outcomes.len(), 3, "a repeated record is dropped by its key");
    assert_eq!(
        outcomes
            .iter()
            .map(|outcome| outcome.dedupe_key.as_str())
            .collect::<HashSet<_>>()
            .len(),
        2
    );
    assert_eq!(shape(&outcomes[..2]), [(Succeeded, "gpt-5", "openai"); 2]);
    assert_eq!(outcomes[0].occurred_at, time("2026-10-09T12:00:02Z"));
    // Old rollouts would show successes without failures.
    assert!(rollout(Some("0.144.5"), "openai").is_empty());
    assert!(rollout(None, "openai").is_empty());
    assert!(rollout(Some("0.159.2"), "ollama").is_empty());
    // A record without a response id or usage is not a response.
    assert!(codex_outcomes(&[
        session_meta(Some("0.159.2"), "openai"),
        turn_context("t1", "gpt-5"),
        codex_line(
            "token_usage_record",
            json!({"turn_id": "t1", "usage": {"output_tokens": 9}}),
            "2026-10-09T12:00:02Z"
        ),
        codex_line(
            "token_usage_record",
            json!({"turn_id": "t1", "response_id": "resp_9"}),
            "2026-10-09T12:00:02Z"
        ),
    ])
    .is_empty());
}

#[test]
fn codex_outcomes_need_one_known_model() {
    // Two models in one turn make it ambiguous; a turn without any has none.
    let switched = codex_outcomes(&[
        session_meta(Some("0.159.2"), "openai"),
        turn_context("t1", "gpt-5"),
        turn_context("t1", "gpt-5-mini"),
        task_started("t1"),
        usage_record("t1", "resp_1", "2026-10-09T12:00:02Z", 50),
        task_complete(
            "t1",
            "2026-10-09T12:00:05Z",
            Some(json!({"message": "x", "codex_error_info": "server_overloaded"})),
        ),
    ]);
    assert!(switched.is_empty());
    let modelless = codex_outcomes(&[
        session_meta(Some("0.159.2"), "openai"),
        task_started("t1"),
        usage_record("t1", "resp_1", "2026-10-09T12:00:02Z", 50),
    ]);
    assert!(modelless.is_empty());
}

#[test]
fn codex_review_sessions_report_no_outcomes() {
    let meta = codex_line(
        "session_meta",
        json!({"id": "g1", "cli_version": "0.159.2", "model_provider": "openai",
            "source": {"subagent": {"other": "guardian"}}}),
        "2026-10-09T12:00:00Z",
    );
    assert!(codex_outcomes(&[
        meta,
        turn_context("t1", "gpt-5"),
        usage_record("t1", "resp_1", "2026-10-09T12:00:02Z", 50),
    ])
    .is_empty());
}

// ---- the monitors -------------------------------------------------------------------------------

fn set_modified(path: &Path, at: DateTime<Utc>) {
    fs::OpenOptions::new()
        .write(true)
        .open(path)
        .unwrap()
        .set_modified(SystemTime::from(at))
        .unwrap();
}

#[test]
fn the_source_monitor_carries_outcomes_apart_from_turns_and_never_twice() {
    let dir = TempDir::new().unwrap();
    let folder = |name: &str| {
        let path = dir.path().join(name);
        fs::create_dir_all(&path).unwrap();
        path
    };
    let (codex, claude) = (folder("codex"), folder("claude"));
    let at = time("2026-10-09T12:10:00Z");
    let claude_file = claude.join("project-a/session.jsonl");
    fs::create_dir_all(claude_file.parent().unwrap()).unwrap();
    fs::write(
        &claude_file,
        jsonl(&[
            real("2026-10-09T12:00:00Z", 1, 400),
            api_error(
                "2026-10-09T12:00:30Z",
                "overload",
                "server_error",
                Some(529),
                "overloaded",
            ),
            real("2026-10-09T12:01:00Z", 2, 400),
        ]),
    )
    .unwrap();
    set_modified(&claude_file, at);
    let codex_file = codex.join("2026/10/09/rollout-1.jsonl");
    fs::create_dir_all(codex_file.parent().unwrap()).unwrap();
    fs::write(
        &codex_file,
        jsonl(&[
            session_meta(Some("0.159.2"), "openai"),
            turn_context("t1", "gpt-5"),
            task_started("t1"),
            usage_record("t1", "resp_1", "2026-10-09T12:00:02Z", 30),
            task_complete(
                "t1",
                "2026-10-09T12:00:05Z",
                Some(json!({"message": "x", "codex_error_info": "internal_server_error"})),
            ),
        ]),
    )
    .unwrap();
    set_modified(&codex_file, at);
    let mut monitor = SourceMonitor::new(
        codex,
        claude,
        folder("grok"),
        folder("gemini"),
        folder("opencode"),
        folder("kimi"),
        folder("kimi-desktop"),
    );
    let mut turns: Vec<TurnMetric> = Vec::new();
    let mut outcomes = Vec::new();
    for _ in 0..6 {
        turns.extend(monitor.poll(at).unwrap());
        outcomes.extend(monitor.take_request_outcomes());
    }
    let mut kinds: Vec<_> = outcomes
        .iter()
        .map(|outcome| (outcome.client, outcome.kind))
        .collect();
    kinds.sort_by_key(|(client, kind)| (*client, format!("{kind:?}")));
    assert_eq!(
        kinds,
        [
            (CLAUDE_CLIENT, Overloaded),
            (CLAUDE_CLIENT, Succeeded),
            (CLAUDE_CLIENT, Succeeded),
            (CODEX_CLIENT, ServerError),
            (CODEX_CLIENT, Succeeded),
        ]
    );
    // Drained once: nothing is reported again, and a file read to its end is not read again.
    assert!(monitor.take_request_outcomes().is_empty());
    monitor.poll(at + Duration::seconds(10)).unwrap();
    assert!(monitor.take_request_outcomes().is_empty());
    // Outcomes are no turns, and no record of a turn carries one.
    assert!(turns
        .iter()
        .all(|turn| !serde_json::to_string(turn).unwrap().contains("outcome")));
}

// ---- the aggregator -----------------------------------------------------------------------------

fn outcome_of(
    client: &'static str,
    key: &str,
    at: &str,
    kind: RequestOutcomeKind,
) -> RequestOutcome {
    let (parser, model, provider) = match client {
        CLAUDE_CLIENT => (CLAUDE_PARSER_VERSION, MODEL, "anthropic"),
        OPENCODE_CLIENT => (OPENCODE_PARSER_VERSION, "gpt-5", "openai"),
        KIMI_CLIENT => (KIMI_PARSER_VERSION, "kimi-for-coding", "moonshot"),
        _ => (CODEX_PARSER_VERSION, "gpt-5", "openai"),
    };
    RequestOutcome::new(
        key.to_owned(),
        time(at),
        client,
        Some("1.2.3".into()),
        parser,
        Some(model),
        Some(provider),
        kind,
    )
    .unwrap()
}

fn outcome(key: &str, at: &str, kind: RequestOutcomeKind) -> RequestOutcome {
    outcome_of(CODEX_CLIENT, key, at, kind)
}

fn time_from_seconds(seconds: i64) -> DateTime<Utc> {
    DateTime::from_timestamp(seconds, 0).unwrap()
}

fn queue(delay_seconds: i64) -> SharingQueue {
    SharingQueue::with_jitter_source(move || Duration::seconds(delay_seconds))
}

/// All entries a far-future batch takes, repeatedly, until none are left.
fn drain(queue: &mut SharingQueue, now: DateTime<Utc>) -> Vec<SharedRequestCount> {
    // The sharing loop looks at least every 30 s, so what came due is queued at its boundary.
    queue.upload_batch(time_from_seconds(now.timestamp().div_euclid(300) * 300));
    let mut entries = Vec::new();
    loop {
        let batch = queue.upload_batch(now);
        if batch.is_empty() {
            return entries;
        }
        queue.ack_batch(&batch);
        entries.extend(batch.request_counts);
    }
}

#[test]
fn outcomes_are_summed_per_bucket_and_queued_one_period_after_it() {
    let mut queue = queue(30);
    queue.enable(time("2026-10-09T09:59:00Z"));
    let now = time("2026-10-09T10:07:00Z");
    queue.enqueue_outcomes(
        &[
            outcome("a", "2026-10-09T10:00:01Z", Succeeded),
            outcome("b", "2026-10-09T10:03:59Z", Succeeded),
            outcome("c", "2026-10-09T10:04:59Z", Overloaded),
            outcome("d", "2026-10-09T10:06:10Z", ServerError),
        ],
        now,
    );
    // Nothing is queued before its bucket's start plus 600 s, and the host is told when to look.
    assert_eq!(queue.request_count_len(), 0);
    assert_eq!(
        queue.next_eligible_after(now),
        Some(time("2026-10-09T10:10:00Z"))
    );
    assert!(queue.upload_batch(time("2026-10-09T10:09:59Z")).is_empty());
    // At the bucket's due moment it is queued, and it leaves after the slot's delay.
    assert!(queue.upload_batch(time("2026-10-09T10:10:00Z")).is_empty());
    assert_eq!(queue.request_count_len(), 1);
    assert_eq!(
        queue.next_eligible_after(time("2026-10-09T10:10:00Z")),
        Some(time("2026-10-09T10:10:30Z"))
    );
    assert!(queue.upload_batch(time("2026-10-09T10:10:29Z")).is_empty());
    let first = queue.upload_batch(time("2026-10-09T10:10:30Z"));
    assert!(first.samples.is_empty());
    let entry = &first.request_counts[0];
    assert_eq!(first.request_counts.len(), 1);
    assert_eq!(entry.observed_at, "2026-10-09T10:00:00Z");
    assert_eq!(
        (entry.succeeded, entry.overloaded, entry.server_error),
        (2, 1, 0)
    );
    assert_eq!(entry.client, "codex");
    assert_eq!(entry.client_version, "1.2.3");
    assert_eq!(entry.app_version, "0.1.22");
    assert_eq!(entry.parser_version, "codex-rollout-v2");
    assert_eq!(entry.metric_version, "request-outcome-v1");
    assert_eq!(entry.model, "gpt-5");
    assert_eq!(entry.provider, "openai");
    // Unacknowledged, it is offered again with the same id; acknowledged, it is gone.
    let retry = queue.upload_batch(time("2026-10-09T10:11:00Z"));
    assert_eq!(retry.request_counts[0].count_id, entry.count_id);
    // The next bucket follows five minutes later.
    queue.upload_batch(time("2026-10-09T10:15:00Z"));
    let second = queue.upload_batch(time("2026-10-09T10:15:30Z"));
    assert_eq!(second.request_counts.len(), 2);
    assert_eq!(second.request_counts[1].observed_at, "2026-10-09T10:05:00Z");
    assert_eq!(second.request_counts[1].server_error, 1);
    queue.ack_batch(&second);
    assert_eq!(queue.request_count_len(), 0);
    assert_eq!(
        queue.next_eligible_after(time("2026-10-09T10:16:00Z")),
        None
    );
}

#[test]
fn request_counts_and_samples_of_one_slot_share_one_delay_and_one_request() {
    let draws = std::sync::Arc::new(std::sync::atomic::AtomicUsize::new(0));
    let counter = draws.clone();
    let mut queue = SharingQueue::with_jitter_source(move || {
        counter.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
        Duration::seconds(17)
    });
    queue.enable(time("2026-10-09T09:59:00Z"));
    let mut turn = TurnMetric::new(
        "turn".into(),
        time("2026-10-09T10:03:00Z"),
        Some("gpt-5".into()),
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
    queue.enqueue(&[turn], time("2026-10-09T10:03:10Z"));
    queue.enqueue_outcomes(
        &[outcome("a", "2026-10-09T10:03:00Z", Succeeded)],
        time("2026-10-09T10:03:10Z"),
    );
    assert!(queue.upload_batch(time("2026-10-09T10:10:00Z")).is_empty());
    assert!(queue.upload_batch(time("2026-10-09T10:10:16Z")).is_empty());
    let batch = queue.upload_batch(time("2026-10-09T10:10:17Z"));
    assert_eq!(batch.samples.len(), 1);
    assert_eq!(batch.request_counts.len(), 1);
    assert_eq!(draws.load(std::sync::atomic::Ordering::SeqCst), 1);
    queue.ack_batch(&batch);
    assert!(queue.is_empty());
    assert_eq!(queue.request_count_len(), 0);
}

#[test]
fn an_outcome_is_counted_once_however_often_it_is_read() {
    let mut queue = queue(0);
    queue.enable(time("2026-10-09T09:59:00Z"));
    let now = time("2026-10-09T10:02:00Z");
    let once = outcome("same", "2026-10-09T10:01:00Z", Succeeded);
    queue.enqueue_outcomes(&[once.clone(), once.clone()], now);
    queue.enqueue_outcomes(&[once.clone()], now + Duration::seconds(30));
    let entries = drain(&mut queue, time("2026-10-09T10:11:00Z"));
    assert_eq!(entries.len(), 1);
    assert_eq!(entries[0].succeeded, 1);
    // Still remembered after its entry left: a file read again does not start a new one.
    queue.enqueue_outcomes(&[once], time("2026-10-09T10:12:00Z"));
    assert!(drain(&mut queue, time("2026-10-09T10:31:00Z")).is_empty());
}

#[test]
fn only_outcomes_after_the_consent_started_and_not_in_the_future_count() {
    let mut queue = queue(0);
    let now = time("2026-10-09T10:02:00Z");
    // Sharing off: nothing is taken.
    queue.enqueue_outcomes(&[outcome("off", "2026-10-09T10:01:00Z", Succeeded)], now);
    queue.enable(time("2026-10-09T10:01:00Z"));
    queue.enqueue_outcomes(
        &[
            outcome("before", "2026-10-09T10:00:59Z", Succeeded),
            outcome("future", "2026-10-09T10:02:01Z", Succeeded),
            outcome("ancient", "2026-10-06T10:01:30Z", Succeeded),
            outcome("at-start", "2026-10-09T10:01:00Z", Succeeded),
        ],
        now,
    );
    let entries = drain(&mut queue, time("2026-10-09T10:11:00Z"));
    assert_eq!(entries.len(), 1);
    assert_eq!(entries[0].succeeded, 1);
    // An outcome dated in the future is not remembered: it counts once its time has come.
    queue.enqueue_outcomes(
        &[outcome("future", "2026-10-09T10:02:01Z", Succeeded)],
        time("2026-10-09T10:03:00Z"),
    );
    assert_eq!(drain(&mut queue, time("2026-10-09T10:21:00Z")).len(), 1);
    // Older than 24 hours at the moment it is taken is dropped, even after consent started.
    let mut old = self::queue(0);
    old.enable(time("2026-10-07T10:00:00Z"));
    old.enqueue_outcomes(
        &[outcome("day-old", "2026-10-08T09:59:00Z", Succeeded)],
        time("2026-10-09T10:00:00Z"),
    );
    assert!(drain(&mut old, time("2026-10-09T11:00:00Z")).is_empty());
}

#[test]
fn a_late_outcome_starts_a_new_entry_for_its_bucket_at_the_next_boundary() {
    let mut queue = queue(0);
    queue.enable(time("2026-10-09T09:59:00Z"));
    queue.enqueue_outcomes(
        &[outcome("first", "2026-10-09T10:01:00Z", Succeeded)],
        time("2026-10-09T10:02:00Z"),
    );
    let sent = queue.upload_batch(time("2026-10-09T10:10:00Z"));
    assert_eq!(sent.request_counts.len(), 1);
    queue.ack_batch(&sent);
    // The bucket was queued at 10:10; an outcome of it read at 10:12:30 waits for 10:15.
    let late_at = time("2026-10-09T10:12:30Z");
    queue.enqueue_outcomes(
        &[outcome("late", "2026-10-09T10:02:00Z", Overloaded)],
        late_at,
    );
    assert_eq!(
        queue.next_eligible_after(late_at),
        Some(time("2026-10-09T10:15:00Z"))
    );
    assert!(queue.upload_batch(time("2026-10-09T10:14:59Z")).is_empty());
    // A second late one before that boundary joins it.
    queue.enqueue_outcomes(
        &[outcome("late-2", "2026-10-09T10:04:00Z", Overloaded)],
        time("2026-10-09T10:13:30Z"),
    );
    let batch = queue.upload_batch(time("2026-10-09T10:15:00Z"));
    assert_eq!(batch.request_counts.len(), 1);
    let entry = &batch.request_counts[0];
    assert_eq!(entry.observed_at, "2026-10-09T10:00:00Z");
    assert_eq!((entry.succeeded, entry.overloaded), (0, 2));
    assert_ne!(entry.count_id, sent.request_counts[0].count_id);
}

#[test]
fn counts_over_10000_are_split_into_entries_that_each_sum_to_at_least_one() {
    let mut queue = queue(0);
    queue.enable(time("2026-10-09T09:59:00Z"));
    let mut outcomes: Vec<RequestOutcome> = (0..10_003)
        .map(|index| outcome(&format!("ok-{index}"), "2026-10-09T10:01:00Z", Succeeded))
        .collect();
    outcomes.extend(
        (0..3).map(|index| outcome(&format!("o-{index}"), "2026-10-09T10:01:00Z", Overloaded)),
    );
    queue.enqueue_outcomes(&outcomes, time("2026-10-09T10:02:00Z"));
    queue.upload_batch(time("2026-10-09T10:10:00Z"));
    let entries = drain(&mut queue, time("2026-10-09T10:12:00Z"));
    assert_eq!(entries.len(), 2);
    let counts: Vec<(u32, u32, u32)> = entries
        .iter()
        .map(|entry| (entry.succeeded, entry.overloaded, entry.server_error))
        .collect();
    assert_eq!(counts, [(10_000, 3, 0), (3, 0, 0)]);
    assert_ne!(entries[0].count_id, entries[1].count_id);
    for entry in &entries {
        assert!(entry.succeeded + entry.overloaded + entry.server_error >= 1);
        assert!(entry.succeeded <= 10_000);
    }
}

#[test]
fn only_shareable_outcomes_are_counted_and_the_rest_is_dropped() {
    let mut queue = queue(0);
    queue.enable(time("2026-10-09T09:59:00Z"));
    let now = time("2026-10-09T10:02:00Z");
    let at = "2026-10-09T10:01:00Z";
    let custom = |key: &str,
                  client: &'static str,
                  parser: &'static str,
                  version: Option<&str>,
                  model: &str,
                  provider: &str| {
        // Built field by field: the constructor already refuses an `unknown` model.
        RequestOutcome {
            dedupe_key: key.into(),
            occurred_at: time(at),
            client,
            client_version: version.map(str::to_owned),
            parser_version: parser,
            model: model.into(),
            provider: provider.into(),
            kind: Succeeded,
        }
    };
    queue.enqueue_outcomes(
        &[
            // Shareable, with a client version the sample rules refuse: sent as `unknown`.
            custom(
                "v",
                CODEX_CLIENT,
                CODEX_PARSER_VERSION,
                Some("0.159 2"),
                "gpt-5",
                "openai",
            ),
            custom(
                "long-version",
                CODEX_CLIENT,
                CODEX_PARSER_VERSION,
                Some(&"9".repeat(41)),
                "gpt-5",
                "openai",
            ),
            custom(
                "plus",
                CLAUDE_CLIENT,
                CLAUDE_PARSER_VERSION,
                Some("2.1.295+x"),
                MODEL,
                "anthropic",
            ),
            // A model the sample rules would send as `unknown` is never sent.
            custom(
                "spaces",
                CODEX_CLIENT,
                CODEX_PARSER_VERSION,
                None,
                "my model",
                "openai",
            ),
            custom(
                "long",
                CODEX_CLIENT,
                CODEX_PARSER_VERSION,
                None,
                &"m".repeat(81),
                "openai",
            ),
            custom(
                "literal",
                CODEX_CLIENT,
                CODEX_PARSER_VERSION,
                None,
                "unknown",
                "openai",
            ),
            // Providers per client.
            custom(
                "cc-openai",
                CLAUDE_CLIENT,
                CLAUDE_PARSER_VERSION,
                None,
                MODEL,
                "openai",
            ),
            custom(
                "cc-bedrock",
                CLAUDE_CLIENT,
                CLAUDE_PARSER_VERSION,
                None,
                MODEL,
                "amazon-bedrock",
            ),
            custom(
                "cc-vertex",
                CLAUDE_CLIENT,
                CLAUDE_PARSER_VERSION,
                None,
                MODEL,
                "google-vertex",
            ),
            custom(
                "cx-anthropic",
                CODEX_CLIENT,
                CODEX_PARSER_VERSION,
                None,
                "gpt-5",
                "anthropic",
            ),
            custom(
                "oc-local",
                OPENCODE_CLIENT,
                OPENCODE_PARSER_VERSION,
                None,
                "qwen",
                "omlx",
            ),
            custom(
                "oc-openrouter",
                OPENCODE_CLIENT,
                OPENCODE_PARSER_VERSION,
                None,
                "qwen",
                "openrouter",
            ),
            custom(
                "oc-xai",
                OPENCODE_CLIENT,
                OPENCODE_PARSER_VERSION,
                None,
                "grok-4",
                "xai",
            ),
            custom(
                "oc-google",
                OPENCODE_CLIENT,
                OPENCODE_PARSER_VERSION,
                None,
                "gemini-3",
                "google",
            ),
            custom(
                "km-openai",
                KIMI_CLIENT,
                KIMI_PARSER_VERSION,
                None,
                "k2",
                "openai",
            ),
            custom(
                "km",
                KIMI_CLIENT,
                KIMI_PARSER_VERSION,
                None,
                "k2",
                "moonshot",
            ),
            // An old parser version, Grok Build and Antigravity are no clients of request counts.
            custom(
                "old-parser",
                CLAUDE_CLIENT,
                "claude-transcript-v3",
                None,
                MODEL,
                "anthropic",
            ),
            custom(
                "grok",
                "grok-build",
                "grok-session-v2",
                None,
                "grok-4",
                "xai",
            ),
            custom(
                "antigravity",
                "antigravity",
                "antigravity-conversation-v1",
                None,
                "gemini-3",
                "google",
            ),
        ],
        now,
    );
    let mut entries: Vec<(String, String, String, String)> = {
        queue.upload_batch(time("2026-10-09T10:10:00Z"));
        drain(&mut queue, time("2026-10-09T10:12:00Z"))
            .into_iter()
            .map(|entry| {
                (
                    entry.client,
                    entry.client_version,
                    entry.model,
                    entry.provider,
                )
            })
            .collect()
    };
    entries.sort();
    let entry = |client: &str, version: &str, model: &str, provider: &str| {
        (
            client.to_owned(),
            version.to_owned(),
            model.to_owned(),
            provider.to_owned(),
        )
    };
    let mut expected = vec![
        entry("codex", "unknown", "gpt-5", "openai"),
        entry("claude-code", "2.1.295+x", MODEL, "anthropic"),
        entry("claude-code", "unknown", MODEL, "amazon-bedrock"),
        entry("claude-code", "unknown", MODEL, "google-vertex"),
        entry("opencode", "unknown", "grok-4", "xai"),
        entry("opencode", "unknown", "gemini-3", "google"),
        entry("kimi-code", "unknown", "k2", "moonshot"),
    ];
    expected.sort();
    assert_eq!(entries, expected);
}

#[test]
fn a_full_queue_drops_the_oldest_entries_and_has_its_own_cap() {
    let mut queue = queue(0);
    queue.enable(time("2026-10-09T09:59:00Z"));
    let outcomes: Vec<RequestOutcome> = (0..MAX_PENDING_REQUEST_COUNTS + 100)
        .map(|index| {
            RequestOutcome::new(
                format!("key-{index}"),
                time("2026-10-09T10:01:00Z"),
                CODEX_CLIENT,
                None,
                CODEX_PARSER_VERSION,
                Some(&format!("model-{index:04}")),
                Some("openai"),
                Succeeded,
            )
            .unwrap()
        })
        .collect();
    queue.enqueue_outcomes(&outcomes, time("2026-10-09T10:02:00Z"));
    queue.upload_batch(time("2026-10-09T10:10:00Z"));
    // The sample queue's own cap is untouched.
    assert!(queue.is_empty());
    assert_eq!(queue.request_count_len(), MAX_PENDING_REQUEST_COUNTS);
    let entries = drain(&mut queue, time("2026-10-09T10:12:00Z"));
    assert_eq!(entries.len(), MAX_PENDING_REQUEST_COUNTS);
    // The first 100 (the oldest queued) are gone.
    assert_eq!(entries[0].model, "model-0100");
    assert_eq!(
        entries.last().unwrap().model,
        format!("model-{:04}", MAX_PENDING_REQUEST_COUNTS + 99)
    );
}

#[test]
fn request_counts_older_than_24_hours_are_dropped_unsent() {
    let mut queue = queue(0);
    queue.enable(time("2026-10-09T09:59:00Z"));
    queue.enqueue_outcomes(
        &[outcome("a", "2026-10-09T10:01:00Z", Succeeded)],
        time("2026-10-09T10:02:00Z"),
    );
    queue.upload_batch(time("2026-10-09T10:10:00Z"));
    assert_eq!(queue.request_count_len(), 1);
    // The bucket started more than 24 h before: never offered.
    assert!(queue.upload_batch(time("2026-10-10T10:01:00Z")).is_empty());
    assert_eq!(queue.request_count_len(), 0);
}

#[test]
fn disabling_sharing_clears_every_pending_count_and_forgets_what_was_seen() {
    let mut queue = queue(0);
    queue.enable(time("2026-10-09T09:59:00Z"));
    let now = time("2026-10-09T10:02:00Z");
    let counted = outcome("a", "2026-10-09T10:01:00Z", Succeeded);
    queue.enqueue_outcomes(
        &[
            counted.clone(),
            outcome("b", "2026-10-09T10:01:30Z", Overloaded),
        ],
        now,
    );
    // One bucket still open, another queued.
    queue.enqueue_outcomes(&[outcome("c", "2026-10-09T09:58:00Z", Succeeded)], now);
    queue.upload_batch(time("2026-10-09T10:10:00Z"));
    queue.enqueue_outcomes(
        &[outcome("d", "2026-10-09T10:11:00Z", Succeeded)],
        time("2026-10-09T10:12:00Z"),
    );
    assert!(queue.request_count_len() > 0);
    queue.disable();
    assert_eq!(queue.request_count_len(), 0);
    assert_eq!(
        queue.next_eligible_after(time("2026-10-09T10:12:00Z")),
        None
    );
    assert!(queue.upload_batch(time("2026-10-09T11:00:00Z")).is_empty());
    // Off, nothing is taken; on again, only what happens after the new start counts, and what
    // was seen before is forgotten.
    queue.enqueue_outcomes(
        &[outcome("e", "2026-10-09T10:12:30Z", Succeeded)],
        time("2026-10-09T10:13:00Z"),
    );
    queue.enable(time("2026-10-09T10:13:00Z"));
    queue.enqueue_outcomes(
        &[counted, outcome("f", "2026-10-09T10:13:30Z", Succeeded)],
        time("2026-10-09T10:14:00Z"),
    );
    let entries = drain(&mut queue, time("2026-10-09T10:40:00Z"));
    assert_eq!(entries.len(), 1);
    assert_eq!(entries[0].succeeded, 1);
}

// ---- the version 2 upload envelope --------------------------------------------------------------

fn entry_of(index: u128, model: &str) -> SharedRequestCount {
    SharedRequestCount {
        count_id: Uuid::from_u128(0x0000_0000_0000_4000_8000_0000_0000_0000 + index),
        observed_at: "2026-10-09T12:00:00Z".into(),
        client: "codex".into(),
        client_version: "0.159.2".into(),
        app_version: crate::APP_VERSION,
        parser_version: CODEX_PARSER_VERSION.into(),
        metric_version: crate::REQUEST_OUTCOME_METRIC_VERSION.into(),
        model: model.into(),
        provider: "openai".into(),
        succeeded: 9_999,
        overloaded: 9_999,
        server_error: 9_999,
    }
}

fn sample_of(index: u128) -> SharedSample {
    let mut metric = TurnMetric::new(
        format!("turn-{index}"),
        time("2026-10-09T12:00:00Z"),
        Some("m".repeat(80)),
        200,
        10.0,
        Some(1.0),
        20.0,
        None,
        Some("9".repeat(40)),
        Some(50),
        Some("primary".into()),
        Some("openai".into()),
        Some("high".into()),
    );
    metric.delegated_output_tokens = Some(0);
    SharedSample::from_metric(
        &metric,
        Uuid::from_u128(0x0000_0000_0000_4000_8000_0000_0000_0000 + index),
    )
    .unwrap()
}

#[test]
fn a_request_with_only_counts_is_a_signed_version_2_envelope_with_both_lists() {
    let now = time("2026-10-09T12:05:00Z");
    let request = signed_request(&[], &[entry_of(1, "gpt-5")], &[3; 32], now).unwrap();
    let body: Value = serde_json::from_slice(&request.body).unwrap();
    assert_eq!(body["schemaVersion"], 2);
    assert_eq!(body["samples"], json!([]));
    assert_eq!(body["requestCounts"].as_array().unwrap().len(), 1);
    // Keys are sorted, like the samples' keys.
    let text = String::from_utf8(request.body.clone()).unwrap();
    assert!(text.starts_with("{\"requestCounts\":[{\"appVersion\":\"0.1.22\",\"client\":\"codex\""));
    assert!(text.contains("\"overloaded\":9999,\"parserVersion\""));
    assert!(text.contains("\"serverError\":9999,\"succeeded\":9999}"));
    assert!(text.ends_with("\"sentAt\":\"2026-10-09T12:05:00Z\"}"));
    // Samples only keep the empty list of counts.
    let samples_only = signed_request(&[sample_of(1)], &[], &[3; 32], now).unwrap();
    let body: Value = serde_json::from_slice(&samples_only.body).unwrap();
    assert_eq!(body["schemaVersion"], 2);
    assert_eq!(body["requestCounts"], json!([]));
    // The signature covers the body.
    use base64::engine::general_purpose::STANDARD as BASE64;
    use base64::Engine;
    use ed25519_dalek::{Signature, Verifier, VerifyingKey};
    let key: [u8; 32] = BASE64
        .decode(&request.public_key)
        .unwrap()
        .try_into()
        .unwrap();
    let signature: [u8; 64] = BASE64
        .decode(&request.signature)
        .unwrap()
        .try_into()
        .unwrap();
    VerifyingKey::from_bytes(&key)
        .unwrap()
        .verify(&request.body, &Signature::from_bytes(&signature))
        .unwrap();
}

#[test]
fn a_request_needs_an_item_and_at_most_50_of_each_list() {
    let now = time("2026-10-09T12:05:00Z");
    assert!(signed_request(&[], &[], &[3; 32], now).is_err());
    let samples: Vec<SharedSample> = (0..51).map(sample_of).collect();
    let entries: Vec<SharedRequestCount> = (0..51).map(|i| entry_of(i, "gpt-5")).collect();
    assert!(signed_request(&samples[..50], &entries[..50], &[3; 32], now).is_ok());
    assert!(signed_request(&samples, &[], &[3; 32], now).is_err());
    assert!(signed_request(&[], &entries, &[3; 32], now).is_err());
}

#[test]
fn an_upload_batch_always_fits_the_request_size_limit() {
    let mut queue = queue(0);
    queue.enable(time("2026-10-09T09:59:00Z"));
    let turns: Vec<TurnMetric> = (0..60)
        .map(|index| {
            let mut metric = TurnMetric::new(
                format!("turn-{index}"),
                time("2026-10-09T10:01:00Z"),
                Some("m".repeat(80)),
                200,
                10.0,
                Some(1.0),
                20.0,
                None,
                Some("9".repeat(40)),
                Some(50),
                Some("primary".into()),
                Some("openai".into()),
                Some("high".into()),
            );
            metric.delegated_output_tokens = Some(0);
            metric
        })
        .collect();
    queue.enqueue(&turns, time("2026-10-09T10:02:00Z"));
    let outcomes: Vec<RequestOutcome> = (0..60)
        .flat_map(|index| {
            // Every entry carries 10,000 of two counts (the widest numbers).
            let model = format!("{}{index:02}", "x".repeat(78));
            (0..2).map(move |kind| {
                RequestOutcome::new(
                    format!("key-{index}-{kind}"),
                    time("2026-10-09T10:01:00Z"),
                    CODEX_CLIENT,
                    Some("9".repeat(40)),
                    CODEX_PARSER_VERSION,
                    Some(&model),
                    Some("openai"),
                    if kind == 0 { Succeeded } else { Overloaded },
                )
                .unwrap()
            })
        })
        .collect();
    queue.enqueue_outcomes(&outcomes, time("2026-10-09T10:02:00Z"));
    let mut samples = 0;
    let mut entries = 0;
    let now = time("2026-10-09T10:12:00Z");
    queue.upload_batch(time("2026-10-09T10:10:00Z"));
    let mut rounds = 0;
    loop {
        let batch = queue.upload_batch(now);
        if batch.is_empty() {
            break;
        }
        rounds += 1;
        assert!(batch.samples.len() <= 50 && batch.request_counts.len() <= 50);
        let request = signed_request(&batch.samples, &batch.request_counts, &[3; 32], now)
            .expect("a batch always fits");
        assert!(request.body.len() <= 65_536);
        samples += batch.samples.len();
        entries += batch.request_counts.len();
        queue.ack_batch(&batch);
        assert!(rounds < 20);
    }
    // Nothing was lost by the trimming, only moved to later requests.
    assert_eq!(samples, 60);
    assert_eq!(entries, 60);
}

#[test]
fn acknowledging_a_batch_removes_its_samples_and_entries_only() {
    let mut queue = queue(0);
    queue.enable(time("2026-10-09T09:59:00Z"));
    queue.enqueue_outcomes(
        &[
            outcome("a", "2026-10-09T10:01:00Z", Succeeded),
            outcome_of(CLAUDE_CLIENT, "b", "2026-10-09T10:01:00Z", Overloaded),
        ],
        time("2026-10-09T10:02:00Z"),
    );
    queue.upload_batch(time("2026-10-09T10:10:00Z"));
    let batch = queue.upload_batch(time("2026-10-09T10:11:00Z"));
    assert_eq!(batch.request_counts.len(), 2);
    let kept = crate::UploadBatch {
        samples: Vec::new(),
        request_counts: vec![batch.request_counts[1].clone()],
    };
    queue.ack_batch(&crate::UploadBatch {
        samples: Vec::new(),
        request_counts: vec![batch.request_counts[0].clone()],
    });
    assert_eq!(queue.request_count_len(), 1);
    queue.ack_batch(&kept);
    assert_eq!(queue.request_count_len(), 0);
}

#[test]
fn a_group_looked_at_late_still_leaves_in_the_slot_of_its_due_time() {
    let mut queue = queue(30);
    queue.enable(time("2026-10-09T09:59:00Z"));
    queue.enqueue_outcomes(
        &[outcome("a", "2026-10-09T10:01:00Z", Succeeded)],
        time("2026-10-09T10:02:00Z"),
    );
    // The host only looks at 10:12: the group is due since 10:10 and leaves at 10:10:30 + nothing.
    let batch = queue.upload_batch(time("2026-10-09T10:12:00Z"));
    assert_eq!(batch.request_counts.len(), 1);
    // The same for a late group: its due time is the boundary it was read before.
    queue.ack_batch(&batch);
    queue.enqueue_outcomes(
        &[outcome("b", "2026-10-09T10:02:00Z", Succeeded)],
        time("2026-10-09T10:13:00Z"),
    );
    assert!(queue.upload_batch(time("2026-10-09T10:15:29Z")).is_empty());
    assert_eq!(
        queue
            .upload_batch(time("2026-10-09T10:20:00Z"))
            .request_counts
            .len(),
        1
    );
}
