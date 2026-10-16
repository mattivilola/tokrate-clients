use super::{example_request_json, sign_batch};
use chrono::{DateTime, Utc};
use serde_json::{json, Value};
use tokrate_core::*;

#[test]
fn headless_package_version_uses_the_shared_signed_wire_contract() {
    let completed = DateTime::parse_from_rfc3339("2026-10-16T14:00:00Z")
        .unwrap()
        .with_timezone(&Utc);
    let tuples = [
        (
            CODEX_CLIENT,
            CODEX_PARSER_VERSION,
            CODEX_METRIC_VERSION,
            "openai",
            "primary",
        ),
        (
            CLAUDE_CLIENT,
            CLAUDE_PARSER_VERSION,
            CLAUDE_METRIC_VERSION,
            "anthropic",
            "primary",
        ),
        (
            CLAUDE_CLIENT,
            CLAUDE_PARSER_VERSION,
            CLAUDE_SUBAGENT_METRIC_VERSION,
            "anthropic",
            "subagent",
        ),
        (
            GROK_CLIENT,
            GROK_PARSER_VERSION,
            GROK_METRIC_VERSION,
            "xai",
            "primary",
        ),
        (
            ANTIGRAVITY_CLIENT,
            ANTIGRAVITY_PARSER_VERSION,
            ANTIGRAVITY_METRIC_VERSION,
            "google",
            "primary",
        ),
        (
            OPENCODE_CLIENT,
            OPENCODE_PARSER_VERSION,
            OPENCODE_METRIC_VERSION,
            "google",
            "primary",
        ),
        (
            KIMI_CLIENT,
            KIMI_PARSER_VERSION,
            KIMI_METRIC_VERSION,
            "moonshot",
            "primary",
        ),
        (
            T3_CODE_CLIENT,
            CODEX_PARSER_VERSION,
            CODEX_METRIC_VERSION,
            "openai",
            "primary",
        ),
        (
            T3_CODE_CLIENT,
            CLAUDE_PARSER_VERSION,
            CLAUDE_METRIC_VERSION,
            "anthropic",
            "primary",
        ),
        (
            T3_CODE_CLIENT,
            CLAUDE_PARSER_VERSION,
            CLAUDE_SUBAGENT_METRIC_VERSION,
            "anthropic",
            "subagent",
        ),
        (
            T3_CODE_CLIENT,
            ANTIGRAVITY_PARSER_VERSION,
            ANTIGRAVITY_METRIC_VERSION,
            "google",
            "primary",
        ),
    ];
    let mut batch = UploadBatch::default();
    for (i, (client, parser, version, provider, kind)) in tuples.into_iter().enumerate() {
        let mut metric = TurnMetric::new_observed(
            format!("synthetic-{i}"),
            completed,
            Some("example-model".into()),
            500,
            12.0,
            Some("1.2.3".into()),
            None,
            Some(kind.into()),
            Some(provider.into()),
            Some("high".into()),
            client,
            parser,
            version,
        );
        metric.delegated_output_tokens = (kind == "primary").then_some(0);
        metric.response_output_tokens = Some(400);
        metric.response_duration_seconds = Some(5.0);
        metric.response_count = Some(1);
        metric.surface = match client {
            ANTIGRAVITY_CLIENT | KIMI_CLIENT => Some(ToolSurface::Cli),
            OPENCODE_CLIENT => None,
            _ => Some(ToolSurface::Other),
        };
        if parser == CODEX_PARSER_VERSION {
            metric.codex_ttft_seconds = Some(0.5);
        }
        batch.samples.push(
            SharedSample::from_metric(
                &metric,
                format!("00000000-0000-4000-8000-{:012}", i + 1)
                    .parse()
                    .unwrap(),
            )
            .unwrap(),
        );
    }
    for (i, (client, parser, provider)) in [
        (CODEX_CLIENT, CODEX_PARSER_VERSION, "openai"),
        (CLAUDE_CLIENT, CLAUDE_PARSER_VERSION, "anthropic"),
        (KIMI_CLIENT, KIMI_PARSER_VERSION, "moonshot"),
        (T3_CODE_CLIENT, CODEX_PARSER_VERSION, "openai"),
        (T3_CODE_CLIENT, CLAUDE_PARSER_VERSION, "anthropic"),
    ]
    .into_iter()
    .enumerate()
    {
        batch.request_counts.push(SharedRequestCount {
            count_id: format!("00000000-0000-4000-8000-{:012}", i + 101)
                .parse()
                .unwrap(),
            observed_at: completed.to_rfc3339_opts(chrono::SecondsFormat::Secs, true),
            client: client.into(),
            client_version: "1.2.3".into(),
            app_version: tokrate_core::APP_VERSION,
            parser_version: parser.into(),
            metric_version: REQUEST_OUTCOME_METRIC_VERSION.into(),
            model: "example-model".into(),
            provider: provider.into(),
            succeeded: 2,
            overloaded: 1,
            server_error: 1,
            throttled: 1,
        });
    }
    let sent = completed + chrono::Duration::minutes(6);
    let request = sign_batch(&batch, &[7; 32], sent).unwrap();
    let body: Value = serde_json::from_slice(&request.body).unwrap();
    assert!(body["samples"]
        .as_array()
        .unwrap()
        .iter()
        .chain(body["requestCounts"].as_array().unwrap())
        .all(|row| row["appVersion"] == crate::APP_VERSION));
    assert!(batch
        .samples
        .iter()
        .all(|row| row.app_version == tokrate_core::APP_VERSION));
    assert!(batch
        .request_counts
        .iter()
        .all(|row| row.app_version == tokrate_core::APP_VERSION));
    assert_eq!(tokrate_core::APP_VERSION, "0.1.28");
    let packet = json!({"provenance":"Generated by the actual headless signed serializer with deterministic synthetic data; no local logs, credentials or uploads", "rawBody":String::from_utf8(request.body).unwrap(),"publicKey":request.public_key,"signature":request.signature});
    let fixture = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("tests/fixtures/rust-headless-v0.1.29-mixed.json");
    if std::env::var_os("TOKRATE_EXPORT_HEADLESS_FIXTURE").is_some() {
        std::fs::write(fixture, serde_json::to_vec_pretty(&packet).unwrap()).unwrap();
    } else {
        assert_eq!(
            packet,
            serde_json::from_slice::<Value>(&std::fs::read(fixture).unwrap()).unwrap()
        );
    }
    let example: Value = serde_json::from_str(&example_request_json()).unwrap();
    assert!(example["samples"]
        .as_array()
        .unwrap()
        .iter()
        .chain(example["requestCounts"].as_array().unwrap())
        .all(|row| row["appVersion"] == crate::APP_VERSION));
}
