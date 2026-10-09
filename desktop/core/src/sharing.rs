use crate::model::{
    bedrock_region_or_unknown, consistent_prompt_cache, ReportedReasoningEffort, ToolSurface,
    TurnMetric, ANTIGRAVITY_CLIENT, ANTIGRAVITY_METRIC_VERSION, ANTIGRAVITY_PARSER_VERSION,
    CLAUDE_CLIENT, CLAUDE_METRIC_VERSION, CLAUDE_PARSER_VERSION, CLAUDE_SUBAGENT_METRIC_VERSION,
    CODEX_CLIENT, CODEX_METRIC_VERSION, CODEX_PARSER_VERSION, GROK_CLIENT, GROK_METRIC_VERSION,
    GROK_PARSER_VERSION, KIMI_CLIENT, KIMI_METRIC_VERSION, KIMI_PARSER_VERSION, OPENCODE_CLIENT,
    OPENCODE_METRIC_VERSION, OPENCODE_PARSER_VERSION,
};
use crate::CoreError;
use base64::engine::general_purpose::STANDARD as BASE64;
use base64::Engine;
use chrono::{DateTime, Duration, SecondsFormat, Utc};
use ed25519_dalek::{Signer, SigningKey};
use rand::{rngs::OsRng, Rng};
use serde::Serialize;
use serde_json::Value;
use std::collections::{HashMap, HashSet, VecDeque};
use uuid::Uuid;

pub const APP_VERSION: &str = "0.1.21";
pub const MAX_PENDING_SAMPLES: usize = 1_000;
const MAX_BATCH_SAMPLES: usize = 50;
const MAX_REQUEST_BYTES: usize = 65_536;
const QUEUE_RETENTION_SECONDS: i64 = 24 * 60 * 60;
/// Samples are timed to this period (`observedAt` is floored to it), and uploads leave at the
/// boundaries between periods.
const OBSERVED_PERIOD_SECONDS: i64 = 300;
/// The samples of an upload slot leave this much longer after its boundary, at most, so the moment
/// a request is sent says no more than the slot does.
const MAX_UPLOAD_JITTER_MS: i64 = 60_000;
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
            (KIMI_CLIENT, KIMI_PARSER_VERSION, KIMI_METRIC_VERSION) => {
                (KIMI_CLIENT, KIMI_PARSER_VERSION, KIMI_METRIC_VERSION, false)
            }
            _ => return None,
        };
        // Kimi Code attributes Moonshot's own API or nothing, and reports no cache writes.
        if client == KIMI_CLIENT
            && (!matches!(
                metric.provider.as_deref(),
                None | Some("moonshot" | "unknown")
            ) || metric.cache_write_input_tokens.is_some())
        {
            return None;
        }
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
/// Claude Code, Google only for Antigravity and OpenCode, and Moonshot only for Kimi Code; any
/// other value or pairing is shared as `unknown`.
fn shared_provider(client: &str, provider: Option<&str>) -> &'static str {
    match (client, provider) {
        (_, Some("openai")) => "openai",
        (_, Some("anthropic")) => "anthropic",
        (_, Some("xai")) => "xai",
        (ANTIGRAVITY_CLIENT | OPENCODE_CLIENT, Some("google")) => "google",
        (KIMI_CLIENT, Some("moonshot")) => "moonshot",
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
    let body = serde_json::to_vec(&envelope_value(samples, now)?)?;
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

/// The envelope as the JSON value that is sent: the one place it is built, so the body of a
/// request and the consent example cannot differ.
fn envelope_value(samples: &[SharedSample], now: DateTime<Utc>) -> Result<Value, CoreError> {
    Ok(serde_json::to_value(SharedSampleEnvelope {
        schema_version: 1,
        sent_at: format_date(now),
        samples: samples.to_vec(),
    })?)
}

/// The "See exactly what is sent" example: obviously fake values (nothing here comes from the
/// user's history) run through the real allowlist and the real envelope, pretty-printed. The
/// fields therefore cannot drift from what a request carries.
pub fn example_request_json() -> String {
    let mut metric = TurnMetric::new(
        "example-local-id-never-uploaded".to_owned(),
        DateTime::<Utc>::from_timestamp(1_767_268_980, 0).expect("a valid example time"),
        Some("example-model".to_owned()),
        1_234,
        20.0,
        Some(0.84),
        61.7,
        None,
        Some("1.2.3".to_owned()),
        Some(400),
        Some("primary".to_owned()),
        Some("openai".to_owned()),
        Some("medium".to_owned()),
    );
    metric.response_output_tokens = Some(1_000);
    metric.response_duration_seconds = Some(12.5);
    metric.response_count = Some(3);
    metric.delegated_output_tokens = Some(0);
    metric.surface = Some(ToolSurface::Cli);
    metric.set_prompt_cache(Some(48_000), Some(36_000), None);
    let sample = SharedSample::from_metric(
        &metric,
        Uuid::parse_str("00000000-0000-4000-8000-000000000000").expect("a valid example id"),
    )
    .expect("the example metric is shareable");
    let sent_at = DateTime::<Utc>::from_timestamp(1_767_269_100, 0).expect("a valid example time");
    let envelope = envelope_value(&[sample], sent_at).expect("the example envelope encodes");
    serde_json::to_string_pretty(&envelope).expect("a JSON value prints")
}

/// Draws the delay after an upload slot's boundary at which that slot's samples leave.
type JitterSource = Box<dyn FnMut() -> Duration + Send>;

/// Memory-only queue for post-consent turns. No key material or account identity is stored here.
/// Uploads leave in slots: the five-minute UTC boundaries (seconds since the epoch divisible by
/// 300), each with one random delay of up to a minute that all of its samples share. A sample is
/// given the first boundary at or after both its queueing time and one full period after the end
/// of its own five-minute period (`observedAt`), and leaves at that boundary plus the slot's
/// delay. So every normally settled turn of a period leaves in the same slot, whenever inside
/// the period it finished, and a turn queued long after it ended (one waiting for its subagent
/// work to settle) leaves at a time that says nothing about when it ended.
pub struct SharingQueue {
    enabled_since: Option<DateTime<Utc>>,
    pending: VecDeque<PendingSample>,
    seen_local_ids: HashSet<String>,
    /// The delay drawn for each slot that has queued samples, by the slot's boundary.
    jitters: HashMap<i64, Duration>,
    jitter_source: JitterSource,
    /// The most samples the queue ever held at once.
    #[cfg(test)]
    peak_len: usize,
}

impl Default for SharingQueue {
    fn default() -> Self {
        Self::new()
    }
}

struct PendingSample {
    local_id: String,
    sample: SharedSample,
    /// The upload slot (boundary, in seconds since the epoch) the sample was given when queued.
    slot: i64,
}

impl SharingQueue {
    /// A queue whose delays come from the operating system's entropy.
    pub fn new() -> Self {
        Self::with_jitter_source(|| {
            Duration::milliseconds(OsRng.gen_range(0..MAX_UPLOAD_JITTER_MS))
        })
    }

    /// A queue with its own delay source (tests); every delay is held to 0 to 60 s.
    pub fn with_jitter_source(mut source: impl FnMut() -> Duration + Send + 'static) -> Self {
        Self {
            enabled_since: None,
            pending: VecDeque::new(),
            seen_local_ids: HashSet::new(),
            jitters: HashMap::new(),
            #[cfg(test)]
            peak_len: 0,
            jitter_source: Box::new(move || {
                source().clamp(
                    Duration::zero(),
                    Duration::milliseconds(MAX_UPLOAD_JITTER_MS),
                )
            }),
        }
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
        self.jitters.clear();
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
            let Some(slot) = upload_slot(&sample, now) else {
                continue;
            };
            self.seen_local_ids.insert(metric.id.clone());
            let source = &mut self.jitter_source;
            self.jitters.entry(slot).or_insert_with(|| source());
            // The oldest go as the newest arrive, so the queue never holds more than the cap.
            if self.pending.len() >= MAX_PENDING_SAMPLES {
                self.pending.pop_front();
            }
            self.pending.push_back(PendingSample {
                local_id: metric.id.clone(),
                sample,
                slot,
            });
            #[cfg(test)]
            {
                self.peak_len = self.peak_len.max(self.pending.len());
            }
        }
        self.forget_unused_jitters();
        if self.seen_local_ids.len() > MAX_SEEN_LOCAL_IDS {
            self.seen_local_ids = self
                .pending
                .iter()
                .map(|pending| pending.local_id.clone())
                .collect();
        }
    }

    /// When a pending sample may leave: its slot's boundary plus the delay drawn for the slot.
    fn eligible_at(&self, pending: &PendingSample) -> DateTime<Utc> {
        let jitter = self
            .jitters
            .get(&pending.slot)
            .copied()
            .unwrap_or_else(Duration::zero);
        DateTime::<Utc>::from_timestamp(pending.slot, 0).unwrap_or(DateTime::<Utc>::MAX_UTC)
            + jitter
    }

    /// Returns up to 50 pending samples whose slot has come and whose delay has passed, in the
    /// order they were queued. The ones of one slot become eligible together, so they leave in
    /// one request (more than 50 take the next). Unacknowledged samples keep their UUID
    /// for retries.
    pub fn batch(&mut self, now: DateTime<Utc>) -> Vec<SharedSample> {
        self.prune(now);
        self.pending
            .iter()
            .filter(|pending| self.eligible_at(pending) <= now)
            .take(MAX_BATCH_SAMPLES)
            .map(|pending| pending.sample.clone())
            .collect()
    }

    pub fn ack(&mut self, sample_ids: &[Uuid]) {
        let acknowledged: HashSet<Uuid> = sample_ids.iter().copied().collect();
        self.pending
            .retain(|pending| !acknowledged.contains(&pending.sample.sample_id));
    }

    /// The earliest moment after `now` at which a waiting sample becomes eligible; `None` when
    /// none is waiting. Samples that are eligible already are not counted: a batch takes them.
    pub fn next_eligible_after(&self, now: DateTime<Utc>) -> Option<DateTime<Utc>> {
        self.pending
            .iter()
            .map(|pending| self.eligible_at(pending))
            .filter(|at| *at > now)
            .min()
    }

    pub fn len(&self) -> usize {
        self.pending.len()
    }

    /// The most samples the queue ever held at once.
    #[cfg(test)]
    pub(crate) fn peak_len(&self) -> usize {
        self.peak_len
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
        self.forget_unused_jitters();
    }

    fn forget_unused_jitters(&mut self) {
        let slots: HashSet<i64> = self.pending.iter().map(|pending| pending.slot).collect();
        self.jitters.retain(|slot, _| slots.contains(slot));
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

/// The upload slot of a sample queued at `queued_at`: the first five-minute UTC boundary at or
/// after both `queued_at` and the end of the period after the sample's own (`observedAt` + two
/// periods). The extra period keeps a turn that only settled after its period ended, a delegated
/// turn waits about 30 s, in the same slot as the turns that finished earlier in that period.
fn upload_slot(sample: &SharedSample, queued_at: DateTime<Utc>) -> Option<i64> {
    let period_start = DateTime::parse_from_rfc3339(&sample.observed_at)
        .ok()?
        .timestamp();
    let queued = queued_at.timestamp() + i64::from(queued_at.timestamp_subsec_nanos() > 0);
    let earliest = queued.max(period_start + 2 * OBSERVED_PERIOD_SECONDS);
    Some(
        earliest.div_euclid(OBSERVED_PERIOD_SECONDS) * OBSERVED_PERIOD_SECONDS
            + if earliest.rem_euclid(OBSERVED_PERIOD_SECONDS) == 0 {
                0
            } else {
                OBSERVED_PERIOD_SECONDS
            },
    )
}

fn format_date(date: DateTime<Utc>) -> String {
    date.to_rfc3339_opts(SecondsFormat::Secs, true)
}
