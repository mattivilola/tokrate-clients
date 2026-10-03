use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};

/// One completed Codex turn, normalized without prompts, responses, or source paths.
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
