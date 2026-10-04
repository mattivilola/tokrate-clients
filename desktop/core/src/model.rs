use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};

pub const CODEX_CLIENT: &str = "codex";
pub const CODEX_PARSER_VERSION: &str = "codex-rollout-v1";
pub const CODEX_METRIC_VERSION: &str = "turn-v1";
pub const CLAUDE_CLIENT: &str = "claude-code";
pub const CLAUDE_PARSER_VERSION: &str = "claude-transcript-v3";
pub const CLAUDE_METRIC_VERSION: &str = "claude-observed-turn-v1";
pub const CLAUDE_SUBAGENT_METRIC_VERSION: &str = "claude-observed-subagent-turn-v1";
pub const GROK_CLIENT: &str = "grok-build";
pub const GROK_PARSER_VERSION: &str = "grok-session-v1";
pub const GROK_METRIC_VERSION: &str = "grok-observed-work-turn-v1";

fn default_client() -> String {
    CODEX_CLIENT.to_owned()
}
fn default_parser_version() -> String {
    CODEX_PARSER_VERSION.to_owned()
}
fn default_metric_version() -> String {
    CODEX_METRIC_VERSION.to_owned()
}

/// One completed coding-tool turn, normalized without prompts, responses, or source paths.
#[derive(Clone, Debug, Deserialize, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct TurnMetric {
    pub id: String,
    pub completed_at: DateTime<Utc>,
    pub model: Option<String>,
    pub output_tokens: i64,
    pub duration_seconds: f64,
    #[serde(rename = "codexTTFTSeconds")]
    pub codex_ttft_seconds: Option<f64>,
    #[serde(rename = "turnThroughputTPS")]
    pub turn_throughput_tps: f64,
    #[serde(rename = "streamingTPS")]
    pub streaming_tps: Option<f64>,
    #[serde(default)]
    pub client_version: Option<String>,
    #[serde(default = "default_client")]
    pub client: String,
    #[serde(default = "default_parser_version")]
    pub parser_version: String,
    #[serde(default = "default_metric_version")]
    pub metric_version: String,
    #[serde(default)]
    pub reasoning_output_tokens: Option<i64>,
    #[serde(default)]
    pub source_kind: Option<String>,
    #[serde(default)]
    pub provider: Option<String>,
    #[serde(default)]
    pub reasoning_effort: Option<String>,
}

impl TurnMetric {
    #[allow(clippy::too_many_arguments)]
    pub fn new(
        id: String,
        completed_at: DateTime<Utc>,
        model: Option<String>,
        output_tokens: i64,
        duration_seconds: f64,
        codex_ttft_seconds: Option<f64>,
        turn_throughput_tps: f64,
        streaming_tps: Option<f64>,
        client_version: Option<String>,
        reasoning_output_tokens: Option<i64>,
        source_kind: Option<String>,
        provider: Option<String>,
        reasoning_effort: Option<String>,
    ) -> Self {
        Self {
            id,
            completed_at,
            model,
            output_tokens,
            duration_seconds,
            codex_ttft_seconds,
            turn_throughput_tps,
            streaming_tps,
            client_version,
            client: default_client(),
            parser_version: default_parser_version(),
            metric_version: default_metric_version(),
            reasoning_output_tokens,
            source_kind,
            provider,
            reasoning_effort: reasoning_effort
                .filter(|value| ReportedReasoningEffort::is_allowed(value)),
        }
    }

    #[allow(clippy::too_many_arguments)]
    pub fn new_observed(
        id: String,
        completed_at: DateTime<Utc>,
        model: Option<String>,
        output_tokens: i64,
        duration_seconds: f64,
        client_version: Option<String>,
        reasoning_output_tokens: Option<i64>,
        source_kind: Option<String>,
        provider: Option<String>,
        reasoning_effort: Option<String>,
        client: &str,
        parser_version: &str,
        metric_version: &str,
    ) -> Self {
        Self {
            id,
            completed_at,
            model,
            output_tokens,
            duration_seconds,
            codex_ttft_seconds: None,
            turn_throughput_tps: if duration_seconds > 0.0 {
                output_tokens as f64 / duration_seconds
            } else {
                f64::NAN
            },
            streaming_tps: None,
            client_version,
            client: client.to_owned(),
            parser_version: parser_version.to_owned(),
            metric_version: metric_version.to_owned(),
            reasoning_output_tokens,
            source_kind,
            provider,
            reasoning_effort: reasoning_effort
                .filter(|value| ReportedReasoningEffort::is_allowed(value)),
        }
    }
}

pub struct ReportedReasoningEffort;

impl ReportedReasoningEffort {
    pub fn is_allowed(value: &str) -> bool {
        matches!(
            value,
            "none" | "minimal" | "low" | "medium" | "high" | "xhigh" | "max" | "ultra"
        )
    }
}
