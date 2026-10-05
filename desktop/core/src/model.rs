use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};

pub const CODEX_CLIENT: &str = "codex";
pub const CODEX_PARSER_VERSION: &str = "codex-rollout-v2";
pub const CODEX_METRIC_VERSION: &str = "turn-v1";
pub const CLAUDE_CLIENT: &str = "claude-code";
pub const CLAUDE_PARSER_VERSION: &str = "claude-transcript-v4";
pub const CLAUDE_METRIC_VERSION: &str = "claude-observed-turn-v1";
pub const CLAUDE_SUBAGENT_METRIC_VERSION: &str = "claude-observed-subagent-turn-v1";
pub const GROK_CLIENT: &str = "grok-build";
pub const GROK_PARSER_VERSION: &str = "grok-session-v2";
pub const GROK_METRIC_VERSION: &str = "grok-observed-work-turn-v1";

/// Contract version of the per-response measurement shared with the Mac client.
pub const RESPONSE_METRIC_VERSION: &str = "response-v1";
/// A response needs at least this many output tokens to count; shorter ones are mostly overhead.
pub const RESPONSE_MIN_OUTPUT_TOKENS: i64 = 200;
/// Longer request-to-end spans are waits, not generation.
pub const RESPONSE_MAX_DURATION_SECONDS: f64 = 600.0;
/// No model streams faster than this; a larger implied speed (of a response or a whole turn) is a
/// measurement error.
pub const MAX_TOKENS_PER_SECOND: f64 = 2_000.0;

/// True when `output_tokens` over `duration_seconds` is a physically possible speed.
pub fn speed_is_plausible(output_tokens: i64, duration_seconds: f64) -> bool {
    duration_seconds.is_finite()
        && duration_seconds > 0.0
        && output_tokens as f64 / duration_seconds <= MAX_TOKENS_PER_SECOND
}

/// True when one API response is long and fast enough to be measured, and not implausibly fast.
pub fn response_qualifies(output_tokens: i64, duration_seconds: f64) -> bool {
    output_tokens >= RESPONSE_MIN_OUTPUT_TOKENS
        && duration_seconds <= RESPONSE_MAX_DURATION_SECONDS
        && speed_is_plausible(output_tokens, duration_seconds)
}

fn default_client() -> String {
    CODEX_CLIENT.to_owned()
}
/// Records saved before the parser version existed were produced by the first Codex parser.
const LEGACY_CODEX_PARSER_VERSION: &str = "codex-rollout-v1";
fn default_parser_version() -> String {
    LEGACY_CODEX_PARSER_VERSION.to_owned()
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
    /// Output tokens of the qualifying API responses of this turn; `None` without any.
    #[serde(default)]
    pub response_output_tokens: Option<i64>,
    /// Seconds the model spent responding (request to last record), summed over those responses.
    #[serde(default)]
    pub response_duration_seconds: Option<f64>,
    #[serde(default)]
    pub response_count: Option<i64>,
    /// Amazon Bedrock inference-profile region prefix (`us`, `eu`, ...); `unknown` without one.
    /// `None` for every other route.
    #[serde(default)]
    pub provider_region: Option<String>,
    /// Output tokens of delegated subagent work started during this primary turn that
    /// `output_tokens` does not already include. `None` while attribution is not final and for
    /// records it does not apply to (subagent turns, records saved before the field existed).
    #[serde(default)]
    pub delegated_output_tokens: Option<i64>,
}

/// Per-turn totals over qualifying responses, accumulated by the parsers.
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct ResponseTotals {
    pub output_tokens: i64,
    pub duration_seconds: f64,
    pub count: i64,
}

impl ResponseTotals {
    pub fn add(&mut self, output_tokens: i64, duration_seconds: f64) {
        self.output_tokens = self.output_tokens.saturating_add(output_tokens);
        self.duration_seconds += duration_seconds;
        self.count += 1;
    }

    /// `(tokens, seconds, count)` options for a [`TurnMetric`]; all `None` when nothing qualified.
    pub fn fields(self) -> (Option<i64>, Option<f64>, Option<i64>) {
        if self.count == 0 {
            (None, None, None)
        } else {
            (
                Some(self.output_tokens),
                Some(self.duration_seconds),
                Some(self.count),
            )
        }
    }
}

/// One qualifying API response, emitted as it completes. Local only: never shared or persisted.
#[derive(Clone, Debug, Deserialize, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ResponseMetric {
    /// Local digest used only to deduplicate; no source identifier is kept.
    pub id: String,
    pub completed_at: DateTime<Utc>,
    pub model: Option<String>,
    pub provider: Option<String>,
    pub client: String,
    pub source_kind: Option<String>,
    pub metric_version: String,
    pub reasoning_effort: Option<String>,
    pub output_tokens: i64,
    pub duration_seconds: f64,
}

impl ResponseMetric {
    pub fn speed(&self) -> f64 {
        self.output_tokens as f64 / self.duration_seconds
    }
}

impl TurnMetric {
    /// The whole-turn throughput is a possible speed; a record above the bound is a measurement
    /// error and is neither kept nor shared.
    pub fn turn_speed_is_plausible(&self) -> bool {
        speed_is_plausible(self.output_tokens, self.duration_seconds)
    }

    /// The response fields as one `(tokens, seconds, count)` triple when they are all present and
    /// consistent with each other and with the turn; `None` otherwise. They travel together or not
    /// at all.
    pub fn plausible_response_timing(&self) -> Option<(i64, f64, i64)> {
        let (tokens, seconds, count) = (
            self.response_output_tokens?,
            self.response_duration_seconds?,
            self.response_count?,
        );
        (count >= 1
            && tokens >= RESPONSE_MIN_OUTPUT_TOKENS.saturating_mul(count)
            && tokens <= self.output_tokens
            && seconds <= self.duration_seconds
            && seconds <= RESPONSE_MAX_DURATION_SECONDS * count as f64
            && speed_is_plausible(tokens, seconds))
        .then_some((tokens, seconds, count))
    }

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
            parser_version: CODEX_PARSER_VERSION.to_owned(),
            metric_version: default_metric_version(),
            reasoning_output_tokens,
            source_kind,
            provider,
            reasoning_effort: reasoning_effort
                .filter(|value| ReportedReasoningEffort::is_allowed(value)),
            response_output_tokens: None,
            response_duration_seconds: None,
            response_count: None,
            provider_region: None,
            delegated_output_tokens: None,
        }
    }

    /// The same record with its delegated subagent output attribution settled.
    pub fn with_delegated_output_tokens(&self, delegated_output_tokens: i64) -> Self {
        Self {
            delegated_output_tokens: Some(delegated_output_tokens),
            ..self.clone()
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
            response_output_tokens: None,
            response_duration_seconds: None,
            response_count: None,
            provider_region: None,
            delegated_output_tokens: None,
        }
    }
}

/// Bedrock inference-profile prefixes that identify where a request is routed.
pub const BEDROCK_REGIONS: [&str; 8] = ["us", "eu", "apac", "global", "jp", "au", "ca", "us-gov"];

/// The allowlisted Bedrock region, or `unknown`.
pub fn bedrock_region_or_unknown(value: Option<&str>) -> &'static str {
    BEDROCK_REGIONS
        .iter()
        .copied()
        .find(|region| Some(*region) == value)
        .unwrap_or("unknown")
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

/// Brand family shown as a letter badge next to a model. Letters only, never logos.
#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum ProviderBadge {
    Anthropic,
    OpenAi,
    Xai,
    Unknown,
}

impl ProviderBadge {
    /// Explicit routing evidence wins; otherwise the model family decides. A Bedrock or Vertex
    /// route is Anthropic only when the model is a Claude model.
    pub fn of(model: Option<&str>, provider: Option<&str>) -> Self {
        let model = model.map(str::to_ascii_lowercase);
        let model = model.as_deref().unwrap_or("");
        match provider {
            Some("openai") => return Self::OpenAi,
            Some("xai") => return Self::Xai,
            Some("anthropic") => return Self::Anthropic,
            _ => {}
        }
        let openai_reasoning = model
            .strip_prefix('o')
            .is_some_and(|rest| rest.starts_with(|c: char| c.is_ascii_digit()));
        if model.starts_with("claude-") {
            Self::Anthropic
        } else if model.starts_with("gpt-") || model.contains("codex") || openai_reasoning {
            Self::OpenAi
        } else if model.starts_with("grok-") {
            Self::Xai
        } else {
            Self::Unknown
        }
    }

    pub fn letter(self) -> Option<char> {
        match self {
            Self::Anthropic => Some('A'),
            Self::OpenAi => Some('O'),
            Self::Xai => Some('X'),
            Self::Unknown => None,
        }
    }

    pub fn label(self) -> &'static str {
        match self {
            Self::Anthropic => "Anthropic",
            Self::OpenAi => "OpenAI",
            Self::Xai => "xAI",
            Self::Unknown => "Unknown provider",
        }
    }
}
