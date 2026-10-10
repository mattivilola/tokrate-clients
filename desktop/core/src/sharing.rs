use crate::model::{
    bedrock_region_or_unknown, consistent_prompt_cache, ReportedReasoningEffort, RequestOutcome,
    RequestOutcomeKind, ToolSurface, TurnMetric, ANTIGRAVITY_CLIENT, ANTIGRAVITY_METRIC_VERSION,
    ANTIGRAVITY_PARSER_VERSION, CLAUDE_CLIENT, CLAUDE_METRIC_VERSION, CLAUDE_PARSER_VERSION,
    CLAUDE_SUBAGENT_METRIC_VERSION, CODEX_CLIENT, CODEX_METRIC_VERSION, CODEX_PARSER_VERSION,
    GROK_CLIENT, GROK_METRIC_VERSION, GROK_PARSER_VERSION, KIMI_CLIENT, KIMI_METRIC_VERSION,
    KIMI_PARSER_VERSION, OPENCODE_CLIENT, OPENCODE_METRIC_VERSION, OPENCODE_PARSER_VERSION,
    REQUEST_OUTCOME_METRIC_VERSION,
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

pub const APP_VERSION: &str = "0.1.22";
pub const MAX_PENDING_SAMPLES: usize = 1_000;
/// The request-count entries wait in a queue of their own with the same cap.
pub const MAX_PENDING_REQUEST_COUNTS: usize = 1_000;
const MAX_BATCH_SAMPLES: usize = 50;
const MAX_BATCH_REQUEST_COUNTS: usize = 50;
/// A request-count entry carries at most this many of each count; a larger total is split.
const MAX_COUNT_PER_ENTRY: u64 = 10_000;
/// The envelope version of an upload (contract "Request outcomes (0.1.22)").
const ENVELOPE_SCHEMA_VERSION: u8 = 2;
/// Outcomes already counted are remembered up to this many, oldest first out.
const MAX_SEEN_OUTCOMES: usize = 50_000;
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

/// Builds the exact JSON bytes that the host sends and signs them with the installation key. Both
/// lists are always in the body (an empty array when there is nothing); at least one item is
/// needed in all.
pub fn signed_request(
    samples: &[SharedSample],
    request_counts: &[SharedRequestCount],
    private_key: &[u8; 32],
    now: DateTime<Utc>,
) -> Result<SignedRequest, CoreError> {
    if samples.len() > MAX_BATCH_SAMPLES
        || request_counts.len() > MAX_BATCH_REQUEST_COUNTS
        || samples.is_empty() && request_counts.is_empty()
    {
        return Err(CoreError::InvalidRequest(
            "a request must contain up to 50 samples and up to 50 request counts, and at least one item",
        ));
    }
    let body = serde_json::to_vec(&envelope_value(samples, request_counts, now)?)?;
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
fn envelope_value(
    samples: &[SharedSample],
    request_counts: &[SharedRequestCount],
    now: DateTime<Utc>,
) -> Result<Value, CoreError> {
    Ok(serde_json::to_value(SharedSampleEnvelope {
        schema_version: ENVELOPE_SCHEMA_VERSION,
        sent_at: format_date(now),
        samples: samples.to_vec(),
        request_counts: request_counts.to_vec(),
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
    // One request-count entry, built by the same validation and splitting as a real one.
    let outcome = RequestOutcome::new(
        "example-local-key-never-uploaded".to_owned(),
        DateTime::<Utc>::from_timestamp(1_767_268_980, 0).expect("a valid example time"),
        CODEX_CLIENT,
        Some("1.2.3".to_owned()),
        CODEX_PARSER_VERSION,
        Some("example-model"),
        Some("openai"),
        RequestOutcomeKind::Succeeded,
    )
    .expect("the example outcome is known");
    let counts = OpenCount {
        succeeded: 41,
        overloaded: 3,
        server_error: 0,
        ..OpenCount::default()
    };
    let request_counts = CountKey::of(&outcome)
        .expect("the example outcome is shareable")
        .entries(&counts, || {
            Uuid::parse_str("00000000-0000-4000-8000-000000000001").expect("a valid example id")
        });
    let sent_at = DateTime::<Utc>::from_timestamp(1_767_269_100, 0).expect("a valid example time");
    let envelope =
        envelope_value(&[sample], &request_counts, sent_at).expect("the example envelope encodes");
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
///
/// Request outcomes are counted per five-minute bucket and enter their own queue of request-count
/// entries when the bucket is one full period over; see [`SharingQueue::enqueue_outcomes`].
pub struct SharingQueue {
    enabled_since: Option<DateTime<Utc>>,
    pending: VecDeque<PendingSample>,
    seen_local_ids: HashSet<String>,
    /// Outcome counts by bucket and model that have not been queued yet.
    open_counts: HashMap<CountKey, OpenCount>,
    pending_counts: VecDeque<PendingCount>,
    seen_outcomes: HashSet<String>,
    seen_outcome_order: VecDeque<String>,
    /// The delay drawn for each slot that has queued samples or entries, by the slot's boundary.
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
            open_counts: HashMap::new(),
            pending_counts: VecDeque::new(),
            seen_outcomes: HashSet::new(),
            seen_outcome_order: VecDeque::new(),
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

    /// Disabling clears pending and deduplication state immediately, request counts included.
    pub fn disable(&mut self) {
        self.enabled_since = None;
        self.pending.clear();
        self.seen_local_ids.clear();
        self.open_counts.clear();
        self.pending_counts.clear();
        self.seen_outcomes.clear();
        self.seen_outcome_order.clear();
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

    /// When something queued for `slot` may leave: the slot's boundary plus the delay drawn for it.
    fn slot_eligible_at(&self, slot: i64) -> DateTime<Utc> {
        let jitter = self
            .jitters
            .get(&slot)
            .copied()
            .unwrap_or_else(Duration::zero);
        DateTime::<Utc>::from_timestamp(slot, 0).unwrap_or(DateTime::<Utc>::MAX_UTC) + jitter
    }

    /// When a pending sample may leave.
    fn eligible_at(&self, pending: &PendingSample) -> DateTime<Utc> {
        self.slot_eligible_at(pending.slot)
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

    /// What one upload carries at `now`: the eligible samples (up to 50) and the eligible
    /// request-count entries (up to 50), together, in the order they were queued, and no more than
    /// fit in 65,536 bytes (entries make room for samples first). Counts of buckets that came
    /// due are queued first. Nothing leaves before its slot's delay is over; unacknowledged items
    /// keep their UUIDs for retries.
    pub fn upload_batch(&mut self, now: DateTime<Utc>) -> UploadBatch {
        self.settle(now);
        let mut batch = UploadBatch {
            samples: self.batch(now),
            request_counts: self
                .pending_counts
                .iter()
                .filter(|pending| self.slot_eligible_at(pending.slot) <= now)
                .take(MAX_BATCH_REQUEST_COUNTS)
                .map(|pending| pending.entry.clone())
                .collect(),
        };
        batch.fit_request_size(now);
        batch
    }

    /// Removes what the server accepted or refused for good.
    pub fn ack_batch(&mut self, batch: &UploadBatch) {
        let sample_ids: Vec<Uuid> = batch
            .samples
            .iter()
            .map(|sample| sample.sample_id)
            .collect();
        self.ack(&sample_ids);
        let acknowledged: HashSet<Uuid> = batch
            .request_counts
            .iter()
            .map(|entry| entry.count_id)
            .collect();
        self.pending_counts
            .retain(|pending| !acknowledged.contains(&pending.entry.count_id));
    }

    /// The earliest moment after `now` at which something waiting becomes eligible, or a bucket of
    /// request outcomes comes due; `None` when nothing waits. Items eligible already are not
    /// counted: a batch takes them.
    pub fn next_eligible_after(&self, now: DateTime<Utc>) -> Option<DateTime<Utc>> {
        let samples = self.pending.iter().map(|pending| self.eligible_at(pending));
        let entries = self
            .pending_counts
            .iter()
            .map(|pending| self.slot_eligible_at(pending.slot));
        let buckets = self
            .open_counts
            .values()
            .filter_map(|open| DateTime::<Utc>::from_timestamp(open.flush_at, 0));
        samples
            .chain(entries)
            .chain(buckets)
            .filter(|at| *at > now)
            .min()
    }

    /// Counts request outcomes. An outcome is taken only while sharing is on, when it happened at
    /// or after the start of the current consent, not in the future and not over 24 hours ago,
    /// and when its model, version and provider are shareable for its client; the same outcome
    /// (by its key) is counted once however often it is read. Outcomes are summed per
    /// (five-minute bucket of their time, client, client version, parser version, model,
    /// provider). A bucket's sums become one queued entry one full period after the bucket
    /// started; an outcome for a bucket that already did starts a new entry, queued at the next
    /// period boundary.
    pub fn enqueue_outcomes(&mut self, outcomes: &[RequestOutcome], now: DateTime<Utc>) {
        let Some(enabled_since) = self.enabled_since else {
            return;
        };
        self.settle(now);
        let now_seconds = now.timestamp() + i64::from(now.timestamp_subsec_nanos() > 0);
        for outcome in outcomes {
            if outcome.occurred_at < enabled_since
                || outcome.occurred_at > now
                || now.timestamp() - outcome.occurred_at.timestamp() > QUEUE_RETENTION_SECONDS
                || self.seen_outcomes.contains(&outcome.dedupe_key)
            {
                continue;
            }
            let Some(key) = CountKey::of(outcome) else {
                continue;
            };
            self.remember_outcome(outcome.dedupe_key.clone());
            // A bucket is queued one full period after it ended (its start plus two periods), or at
            // the next period boundary when that has passed already.
            let due = key.bucket + 2 * OBSERVED_PERIOD_SECONDS;
            let open = self.open_counts.entry(key).or_insert_with(|| OpenCount {
                flush_at: due.max(next_boundary(now_seconds)),
                ..OpenCount::default()
            });
            match outcome.kind {
                RequestOutcomeKind::Succeeded => open.succeeded += 1,
                RequestOutcomeKind::Overloaded => open.overloaded += 1,
                RequestOutcomeKind::ServerError => open.server_error += 1,
            }
        }
    }

    fn remember_outcome(&mut self, key: String) {
        if self.seen_outcomes.insert(key.clone()) {
            self.seen_outcome_order.push_back(key);
            while self.seen_outcome_order.len() > MAX_SEEN_OUTCOMES {
                if let Some(oldest) = self.seen_outcome_order.pop_front() {
                    self.seen_outcomes.remove(&oldest);
                }
            }
        }
    }

    /// Queues the entries of every bucket that came due by `now`.
    fn settle(&mut self, now: DateTime<Utc>) {
        if self.open_counts.is_empty() {
            return;
        }
        let mut due: Vec<CountKey> = self
            .open_counts
            .iter()
            .filter(|(_, open)| open.flush_at <= now.timestamp())
            .map(|(key, _)| key.clone())
            .collect();
        due.sort();
        for key in due {
            let Some(open) = self.open_counts.remove(&key) else {
                continue;
            };
            if now.timestamp() - key.bucket > QUEUE_RETENTION_SECONDS {
                continue;
            }
            // The slot comes from the due time, not from when the host happened to look: the
            // group shares the slot, and so the delay, of the samples of its bucket.
            let slot = open.flush_at;
            let source = &mut self.jitter_source;
            self.jitters.entry(slot).or_insert_with(|| source());
            for entry in key.entries(&open, Uuid::new_v4) {
                // The oldest go as the newest arrive, like the samples.
                if self.pending_counts.len() >= MAX_PENDING_REQUEST_COUNTS {
                    self.pending_counts.pop_front();
                }
                self.pending_counts.push_back(PendingCount { entry, slot });
            }
        }
        self.forget_unused_jitters();
    }

    /// Request-count entries waiting to be uploaded.
    pub fn request_count_len(&self) -> usize {
        self.pending_counts.len()
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
        let fresh = |observed_at: &str| {
            DateTime::parse_from_rfc3339(observed_at).is_ok_and(|observed_at| {
                now.timestamp() - observed_at.timestamp() <= QUEUE_RETENTION_SECONDS
            })
        };
        self.pending
            .retain(|pending| fresh(&pending.sample.observed_at));
        self.pending_counts
            .retain(|pending| fresh(&pending.entry.observed_at));
        self.forget_unused_jitters();
    }

    fn forget_unused_jitters(&mut self) {
        let slots: HashSet<i64> = self
            .pending
            .iter()
            .map(|pending| pending.slot)
            .chain(self.pending_counts.iter().map(|pending| pending.slot))
            .collect();
        self.jitters.retain(|slot, _| slots.contains(slot));
    }
}

/// One request-count entry waiting for its upload slot.
struct PendingCount {
    entry: SharedRequestCount,
    slot: i64,
}

/// What the entries of one (bucket, client, version, model, provider) have counted so far, and
/// when they are queued.
#[derive(Default)]
struct OpenCount {
    /// Seconds since the epoch at which the entry is queued.
    flush_at: i64,
    succeeded: u64,
    overloaded: u64,
    server_error: u64,
}

/// What request counts are summed by. Everything in it is already validated and shareable.
#[derive(Clone, Debug, Eq, Hash, Ord, PartialEq, PartialOrd)]
struct CountKey {
    /// Start of the five-minute bucket, in seconds since the epoch.
    bucket: i64,
    client: &'static str,
    client_version: String,
    parser_version: &'static str,
    model: String,
    provider: &'static str,
}

impl CountKey {
    /// The key of an outcome, or `None` when it may not be shared: an unknown client or parser
    /// version, a model that does not match the public pattern (an `unknown` model is never
    /// sent), or a provider the client's allowlist lacks.
    fn of(outcome: &RequestOutcome) -> Option<Self> {
        let (client, parser_version) = match (outcome.client, outcome.parser_version) {
            (CLAUDE_CLIENT, CLAUDE_PARSER_VERSION) => (CLAUDE_CLIENT, CLAUDE_PARSER_VERSION),
            (CODEX_CLIENT, CODEX_PARSER_VERSION) => (CODEX_CLIENT, CODEX_PARSER_VERSION),
            (OPENCODE_CLIENT, OPENCODE_PARSER_VERSION) => {
                (OPENCODE_CLIENT, OPENCODE_PARSER_VERSION)
            }
            (KIMI_CLIENT, KIMI_PARSER_VERSION) => (KIMI_CLIENT, KIMI_PARSER_VERSION),
            _ => return None,
        };
        let model = Some(outcome.model.as_str())
            .filter(|model| *model != "unknown" && safe_identifier(model, 80, false))?;
        Some(Self {
            bucket: outcome
                .occurred_at
                .timestamp()
                .div_euclid(OBSERVED_PERIOD_SECONDS)
                * OBSERVED_PERIOD_SECONDS,
            client,
            client_version: outcome
                .client_version
                .as_deref()
                .filter(|value| safe_identifier(value, 40, true))
                .unwrap_or("unknown")
                .to_owned(),
            parser_version,
            model: model.to_owned(),
            provider: request_count_provider(client, &outcome.provider)?,
        })
    }

    /// The entries these counts make: one, or more when a count passes 10,000, each with a fresh
    /// id from `new_id` and a sum of at least one. Nothing for counts that are all zero.
    fn entries(
        &self,
        counts: &OpenCount,
        mut new_id: impl FnMut() -> Uuid,
    ) -> Vec<SharedRequestCount> {
        let observed_at = DateTime::<Utc>::from_timestamp(self.bucket, 0)
            .map(format_date)
            .unwrap_or_default();
        let mut remaining = [counts.succeeded, counts.overloaded, counts.server_error];
        let mut entries = Vec::new();
        while remaining.iter().any(|count| *count > 0) {
            let take = remaining.map(|count| count.min(MAX_COUNT_PER_ENTRY));
            for (left, taken) in remaining.iter_mut().zip(take) {
                *left -= taken;
            }
            entries.push(SharedRequestCount {
                count_id: new_id(),
                observed_at: observed_at.clone(),
                client: self.client.to_owned(),
                client_version: self.client_version.clone(),
                app_version: APP_VERSION,
                parser_version: self.parser_version.to_owned(),
                metric_version: REQUEST_OUTCOME_METRIC_VERSION.to_owned(),
                model: self.model.clone(),
                provider: self.provider.to_owned(),
                succeeded: take[0] as u32,
                overloaded: take[1] as u32,
                server_error: take[2] as u32,
            });
        }
        entries
    }
}

/// The providers a client's request counts may name (contract "Request outcomes (0.1.22)"). Not
/// `unknown`, and nothing the tool merely passes through (an OpenCode gateway or local server).
fn request_count_provider(client: &str, provider: &str) -> Option<&'static str> {
    let allowed: &[&'static str] = match client {
        CLAUDE_CLIENT => &["anthropic", "amazon-bedrock", "google-vertex"],
        CODEX_CLIENT => &["openai"],
        OPENCODE_CLIENT => &["anthropic", "openai", "google", "xai"],
        KIMI_CLIENT => &["moonshot"],
        _ => &[],
    };
    allowed.iter().copied().find(|allowed| *allowed == provider)
}

/// How many requests of one model succeeded and failed on the provider's side during one
/// five-minute period (contract "Request outcomes (0.1.22)"). A strictly allowlisted row like a
/// sample, with no error text and nothing that identifies a turn.
#[derive(Clone, Debug, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SharedRequestCount {
    pub count_id: Uuid,
    pub observed_at: String,
    pub client: String,
    pub client_version: String,
    pub app_version: &'static str,
    pub parser_version: String,
    pub metric_version: String,
    pub model: String,
    pub provider: String,
    pub succeeded: u32,
    pub overloaded: u32,
    pub server_error: u32,
}

/// The samples and request-count entries one upload carries.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct UploadBatch {
    pub samples: Vec<SharedSample>,
    pub request_counts: Vec<SharedRequestCount>,
}

impl UploadBatch {
    pub fn is_empty(&self) -> bool {
        self.samples.is_empty() && self.request_counts.is_empty()
    }

    /// Takes the last items off until the signed body fits: entries first, then samples (one
    /// always stays), so a request never exceeds the limit and never stalls the queue.
    fn fit_request_size(&mut self, now: DateTime<Utc>) {
        let too_big = |batch: &Self| {
            envelope_value(&batch.samples, &batch.request_counts, now)
                .and_then(|value| Ok(serde_json::to_vec(&value)?))
                .map_or(true, |body| body.len() > MAX_REQUEST_BYTES)
        };
        while too_big(self) && !self.request_counts.is_empty() {
            self.request_counts.pop();
        }
        while too_big(self) && self.samples.len() > 1 {
            self.samples.pop();
        }
    }
}

#[derive(Clone, Debug, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SharedSampleEnvelope {
    pub schema_version: u8,
    pub sent_at: String,
    pub samples: Vec<SharedSample>,
    pub request_counts: Vec<SharedRequestCount>,
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
    Some(slot_after(period_start, queued_at))
}

/// The slot of something queued at `queued_at` that belongs to the period starting at
/// `period_start`: the first boundary at or after both `queued_at` and the end of the next period.
fn slot_after(period_start: i64, queued_at: DateTime<Utc>) -> i64 {
    let queued = queued_at.timestamp() + i64::from(queued_at.timestamp_subsec_nanos() > 0);
    next_boundary(queued.max(period_start + 2 * OBSERVED_PERIOD_SECONDS))
}

/// The first five-minute boundary at or after `seconds`.
fn next_boundary(seconds: i64) -> i64 {
    seconds.div_euclid(OBSERVED_PERIOD_SECONDS) * OBSERVED_PERIOD_SECONDS
        + if seconds.rem_euclid(OBSERVED_PERIOD_SECONDS) == 0 {
            0
        } else {
            OBSERVED_PERIOD_SECONDS
        }
}

fn format_date(date: DateTime<Utc>) -> String {
    date.to_rfc3339_opts(SecondsFormat::Secs, true)
}
