use crate::model::{
    bedrock_region_or_unknown, consistent_prompt_cache, ReportedReasoningEffort, ToolSurface,
    TurnMetric, ANTIGRAVITY_CLIENT, ANTIGRAVITY_METRIC_VERSION, ANTIGRAVITY_PARSER_VERSION,
    CLAUDE_CLIENT, CLAUDE_METRIC_VERSION, CLAUDE_PARSER_VERSION, CLAUDE_SUBAGENT_METRIC_VERSION,
    CODEX_CLIENT, CODEX_METRIC_VERSION, CODEX_PARSER_VERSION, GROK_CLIENT, GROK_METRIC_VERSION,
    GROK_PARSER_VERSION, OPENCODE_CLIENT, OPENCODE_METRIC_VERSION, OPENCODE_PARSER_VERSION,
};
use crate::CoreError;
use base64::engine::general_purpose::STANDARD as BASE64;
use base64::Engine;
use chrono::{DateTime, SecondsFormat, Utc};
use ed25519_dalek::{Signer, SigningKey};
use serde::Serialize;
use serde_json::Value;
use std::collections::{HashSet, VecDeque};
use uuid::Uuid;

pub const APP_VERSION: &str = "0.1.19";
pub const MAX_PENDING_SAMPLES: usize = 1_000;
const MAX_BATCH_SAMPLES: usize = 50;
const MAX_REQUEST_BYTES: usize = 65_536;
const QUEUE_RETENTION_SECONDS: i64 = 24 * 60 * 60;
const MAX_SEEN_LOCAL_IDS: usize = 50_000;
/// The upper bound the service accepts for delegated subagent output of one turn.
const MAX_DELEGATED_OUTPUT_TOKENS: i64 = 100_000_000;

/// A strictly allowlisted telemetry row. The local metric pseudonym is never included.
#[derive(Clone, Debug, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SharedSample {
    pub sample_id: Uuid,
    pub observed_at: String,
    pub client: String,
    pub client_version: String,
    pub app_version: &'static str,
    pub parser_version: String,
    pub metric_version: String,
    pub model: String,
    pub provider: String,
    pub reasoning_effort: String,
    pub source_kind: String,
    pub output_tokens: i64,
    pub reasoning_output_tokens: Option<i64>,
    pub duration_ms: f64,
    pub ttft_ms: Option<f64>,
    /// Output tokens of the turn's qualifying API responses (always serialized, null if none).
    pub response_output_tokens: Option<i64>,
    pub response_duration_ms: Option<f64>,
    pub response_count: Option<i64>,
    /// Amazon Bedrock inference-profile region (`us`, `eu`, ... or `unknown`); null otherwise.
    pub provider_region: Option<String>,
    /// Output tokens of subagent work the turn started (always serialized): a number for
    /// primary turns, null for every other source kind.
    pub delegated_output_tokens: Option<i64>,
    /// Where the coding tool ran, as a category (always serialized, null when unknown).
    pub surface: Option<ToolSurface>,
    /// Prompt-cache usage (always serialized, null when the source does not report it): input
    /// tokens of the turn including cached ones, those read from the cache, and those written to
    /// it (Claude Code only).
    pub input_tokens: Option<i64>,
    pub cache_read_input_tokens: Option<i64>,
    pub cache_write_input_tokens: Option<i64>,
}

impl SharedSample {
    pub fn from_metric(metric: &TurnMetric, sample_id: Uuid) -> Option<Self> {
        let (client, parser_version, metric_version, supports_ttft) = match (
            metric.client.as_str(),
            metric.parser_version.as_str(),
            metric.metric_version.as_str(),
        ) {
            (CODEX_CLIENT, CODEX_PARSER_VERSION, CODEX_METRIC_VERSION) => (
                CODEX_CLIENT,
                CODEX_PARSER_VERSION,
                CODEX_METRIC_VERSION,
                true,
            ),
            (CLAUDE_CLIENT, CLAUDE_PARSER_VERSION, CLAUDE_METRIC_VERSION) => (
                CLAUDE_CLIENT,
                CLAUDE_PARSER_VERSION,
                CLAUDE_METRIC_VERSION,
                false,
            ),
            (CLAUDE_CLIENT, CLAUDE_PARSER_VERSION, CLAUDE_SUBAGENT_METRIC_VERSION) => (
                CLAUDE_CLIENT,
                CLAUDE_PARSER_VERSION,
                CLAUDE_SUBAGENT_METRIC_VERSION,
                false,
            ),
            (GROK_CLIENT, GROK_PARSER_VERSION, GROK_METRIC_VERSION) => {
                (GROK_CLIENT, GROK_PARSER_VERSION, GROK_METRIC_VERSION, false)
            }
            (ANTIGRAVITY_CLIENT, ANTIGRAVITY_PARSER_VERSION, ANTIGRAVITY_METRIC_VERSION) => (
                ANTIGRAVITY_CLIENT,
                ANTIGRAVITY_PARSER_VERSION,
                ANTIGRAVITY_METRIC_VERSION,
                false,
            ),
            (OPENCODE_CLIENT, OPENCODE_PARSER_VERSION, OPENCODE_METRIC_VERSION) => (
                OPENCODE_CLIENT,
                OPENCODE_PARSER_VERSION,
                OPENCODE_METRIC_VERSION,
                false,
            ),
            _ => return None,
        };
        // OpenCode keeps the raw provider id (a gateway, a vendor plan, a local server) locally;
        // only the providers of the public allowlist, or none, may leave the device.
        if client == OPENCODE_CLIENT
            && !matches!(
                metric.provider.as_deref(),
                None | Some("anthropic" | "openai" | "google" | "xai" | "unknown")
            )
        {
            return None;
        }
        let duration_ms = metric.duration_seconds * 1_000.0;
        if !duration_ms.is_finite()
            || !(1.0..=86_400_000.0).contains(&duration_ms)
            || !(0..=10_000_000).contains(&metric.output_tokens)
            || !metric.turn_speed_is_plausible()
        {
            return None;
        }
        // A primary turn is shared once its delegated output is final; other kinds carry null.
        let source_kind = match metric.source_kind.as_deref() {
            Some("primary") => "primary",
            Some("subagent") => "subagent",
            _ => "unknown",
        };
        let delegated_output_tokens = if source_kind == "primary" {
            Some(
                metric
                    .delegated_output_tokens
                    .filter(|value| (0..=MAX_DELEGATED_OUTPUT_TOKENS).contains(value))?,
            )
        } else {
            None
        };
        let observed_bucket = metric.completed_at.timestamp().div_euclid(300) * 300;
        let observed_at = DateTime::<Utc>::from_timestamp(observed_bucket, 0)?;
        let reasoning_output_tokens = metric
            .reasoning_output_tokens
            .filter(|value| (0..=metric.output_tokens).contains(value));
        let ttft_ms = supports_ttft
            .then_some(metric.codex_ttft_seconds)
            .flatten()
            .and_then(|value| {
                let milliseconds = value * 1_000.0;
                (milliseconds.is_finite() && (0.0..=duration_ms).contains(&milliseconds))
                    .then_some(milliseconds)
            });
        let (response_output_tokens, response_duration_ms, response_count) =
            shared_response_fields(metric);
        let provider = shared_provider(client, metric.provider.as_deref());
        let (input_tokens, cache_read_input_tokens, cache_write_input_tokens) =
            consistent_prompt_cache(
                metric.input_tokens,
                metric.cache_read_input_tokens,
                metric.cache_write_input_tokens,
            );
        Some(Self {
            sample_id,
            observed_at: format_date(observed_at),
            client: client.to_owned(),
            client_version: metric
                .client_version
                .as_deref()
                .filter(|value| safe_identifier(value, 40, true))
                .unwrap_or("unknown")
                .to_owned(),
            app_version: APP_VERSION,
            parser_version: parser_version.to_owned(),
            metric_version: metric_version.to_owned(),
            model: metric
                .model
                .as_deref()
                .filter(|value| safe_identifier(value, 80, false))
                .unwrap_or("unknown")
                .to_owned(),
            provider: provider.to_owned(),
            reasoning_effort: metric
                .reasoning_effort
                .as_deref()
                .filter(|value| ReportedReasoningEffort::is_allowed(value))
                .unwrap_or("unknown")
                .to_owned(),
            source_kind: source_kind.to_owned(),
            output_tokens: metric.output_tokens,
            reasoning_output_tokens,
            duration_ms,
            ttft_ms,
            response_output_tokens,
            response_duration_ms,
            response_count,
            provider_region: (provider == "amazon-bedrock")
                .then(|| bedrock_region_or_unknown(metric.provider_region.as_deref()).to_owned()),
            delegated_output_tokens,
            surface: metric.surface,
            input_tokens,
            cache_read_input_tokens,
            cache_write_input_tokens,
        })
    }
}

/// The response fields travel together or not at all: any inconsistency with the turn drops them.
fn shared_response_fields(metric: &TurnMetric) -> (Option<i64>, Option<f64>, Option<i64>) {
    match metric.plausible_response_timing() {
        Some((tokens, seconds, count)) => (Some(tokens), Some(seconds * 1_000.0), Some(count)),
        None => (None, None, None),
    }
}

/// Providers the public allowlist accepts. Bedrock and Vertex routes are attributed only for
/// Claude Code and Google only for Antigravity and OpenCode; any other value or pairing is shared
/// as `unknown`.
fn shared_provider(client: &str, provider: Option<&str>) -> &'static str {
    match (client, provider) {
        (_, Some("openai")) => "openai",
        (_, Some("anthropic")) => "anthropic",
        (_, Some("xai")) => "xai",
        (ANTIGRAVITY_CLIENT | OPENCODE_CLIENT, Some("google")) => "google",
        (CLAUDE_CLIENT, Some("amazon-bedrock")) => "amazon-bedrock",
        (CLAUDE_CLIENT, Some("google-vertex")) => "google-vertex",
        _ => "unknown",
    }
}

/// Signed upload body returned to the host; credentials never enter local history or the queue.
#[derive(Clone, Debug, PartialEq)]
pub struct SignedRequest {
    pub body: Vec<u8>,
    pub public_key: String,
    pub signature: String,
}

/// Builds the exact JSON bytes that the host sends and signs them with the installation key.
pub fn signed_request(
    samples: &[SharedSample],
    private_key: &[u8; 32],
    now: DateTime<Utc>,
) -> Result<SignedRequest, CoreError> {
    if samples.is_empty() || samples.len() > MAX_BATCH_SAMPLES {
        return Err(CoreError::InvalidRequest(
            "a request must contain between 1 and 50 samples",
        ));
    }
    let body_value: Value = serde_json::to_value(SharedSampleEnvelope {
        schema_version: 1,
        sent_at: format_date(now),
        samples: samples.to_vec(),
    })?;
    let body = serde_json::to_vec(&body_value)?;
    if body.len() > MAX_REQUEST_BYTES {
        return Err(CoreError::InvalidRequest(
            "the signed request exceeds 65,536 bytes",
        ));
    }
    let signing_key = SigningKey::from_bytes(private_key);
    let signature = signing_key.sign(&body);
    Ok(SignedRequest {
        body,
        public_key: BASE64.encode(signing_key.verifying_key().to_bytes()),
        signature: BASE64.encode(signature.to_bytes()),
    })
}

/// Memory-only queue for post-consent turns. No key material or account identity is stored here.
#[derive(Default)]
pub struct SharingQueue {
    enabled_since: Option<DateTime<Utc>>,
    pending: VecDeque<PendingSample>,
    seen_local_ids: HashSet<String>,
}

struct PendingSample {
    local_id: String,
    sample: SharedSample,
}

impl SharingQueue {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn enable(&mut self, now: DateTime<Utc>) {
        if self.enabled_since.is_none() {
            self.enabled_since = Some(now);
        }
    }

    /// Disabling clears pending and deduplication state immediately.
    pub fn disable(&mut self) {
        self.enabled_since = None;
        self.pending.clear();
        self.seen_local_ids.clear();
    }

    pub fn enqueue(&mut self, metrics: &[TurnMetric], now: DateTime<Utc>) {
        let Some(enabled_since) = self.enabled_since else {
            return;
        };
        self.prune(now);
        for metric in metrics {
            if metric.completed_at < enabled_since
                || metric.completed_at > now
                || self.seen_local_ids.contains(&metric.id)
                // A primary turn is re-emitted once its delegated output is final; sharing it
                // earlier would send an incomplete turn, and marking it seen would drop the
                // final version.
                || metric.source_kind.as_deref() == Some("primary")
                    && metric.delegated_output_tokens.is_none()
            {
                continue;
            }
            let Some(sample) = SharedSample::from_metric(metric, Uuid::new_v4()) else {
                continue;
            };
            self.seen_local_ids.insert(metric.id.clone());
            self.pending.push_back(PendingSample {
                local_id: metric.id.clone(),
                sample,
            });
        }
        while self.pending.len() > MAX_PENDING_SAMPLES {
            self.pending.pop_front();
        }
        if self.seen_local_ids.len() > MAX_SEEN_LOCAL_IDS {
            self.seen_local_ids = self
                .pending
                .iter()
                .map(|pending| pending.local_id.clone())
                .collect();
        }
    }

    /// Returns up to 50 pending samples. Unacknowledged samples keep their UUID for retries.
    pub fn batch(&mut self, now: DateTime<Utc>) -> Vec<SharedSample> {
        self.prune(now);
        self.pending
            .iter()
            .take(MAX_BATCH_SAMPLES)
            .map(|pending| pending.sample.clone())
            .collect()
    }

    pub fn ack(&mut self, sample_ids: &[Uuid]) {
        let acknowledged: HashSet<Uuid> = sample_ids.iter().copied().collect();
        self.pending
            .retain(|pending| !acknowledged.contains(&pending.sample.sample_id));
    }

    pub fn len(&self) -> usize {
        self.pending.len()
    }

    pub fn is_empty(&self) -> bool {
        self.pending.is_empty()
    }

    fn prune(&mut self, now: DateTime<Utc>) {
        self.pending.retain(|pending| {
            let Ok(observed_at) = DateTime::parse_from_rfc3339(&pending.sample.observed_at) else {
                return false;
            };
            now.timestamp() - observed_at.timestamp() <= QUEUE_RETENTION_SECONDS
        });
    }
}

#[derive(Clone, Debug, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SharedSampleEnvelope {
    pub schema_version: u8,
    pub sent_at: String,
    pub samples: Vec<SharedSample>,
}

fn safe_identifier(value: &str, maximum: usize, plus_allowed: bool) -> bool {
    !value.is_empty()
        && value.len() <= maximum
        && value.bytes().all(|byte| {
            byte.is_ascii_alphanumeric()
                || matches!(byte, b'.' | b'_' | b'-')
                || plus_allowed && byte == b'+'
        })
}

fn format_date(date: DateTime<Utc>) -> String {
    date.to_rfc3339_opts(SecondsFormat::Secs, true)
}
