//! Bounded, reconciled per-request prompt-size summaries.

use serde::{Deserialize, Serialize};
use std::collections::HashMap;

pub const MAX_PROMPT_SIZE_REQUESTS: usize = 4_096;
/// Maximum aggregate input or cache-read count the service accepts in any one bin.
pub const MAX_PROMPT_SIZE_BIN_TOKENS: i64 = 1_000_000_000;
pub const PROMPT_SIZE_BUCKETS: [&str; 6] = [
    "under-8k",
    "8k-32k",
    "32k-64k",
    "64k-128k",
    "128k-256k",
    "256k-plus",
];

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct PromptSizeBucket {
    pub bucket: String,
    pub request_count: u32,
    pub input_tokens: i64,
    pub cache_read_input_tokens: i64,
}

fn bucket_for(input_tokens: i64) -> usize {
    match input_tokens {
        0..=7_999 => 0,
        8_000..=31_999 => 1,
        32_000..=63_999 => 2,
        64_000..=127_999 => 3,
        128_000..=255_999 => 4,
        _ => 5,
    }
}

/// Returns the exact `(input, cache-read)` sums when a sparse canonical histogram is valid.
pub fn validate_prompt_size_buckets(buckets: &[PromptSizeBucket]) -> Option<(i64, i64)> {
    if buckets.is_empty() || buckets.len() > PROMPT_SIZE_BUCKETS.len() {
        return None;
    }
    let mut count_total = 0_u64;
    let mut input_total = 0_i64;
    let mut read_total = 0_i64;
    let mut last_index = None;
    for bucket in buckets {
        let index = PROMPT_SIZE_BUCKETS
            .iter()
            .position(|name| *name == bucket.bucket)?;
        if last_index.is_some_and(|last| index <= last) || bucket.request_count == 0 {
            return None;
        }
        last_index = Some(index);
        count_total = count_total.checked_add(u64::from(bucket.request_count))?;
        if count_total > MAX_PROMPT_SIZE_REQUESTS as u64
            || bucket.input_tokens < 0
            || bucket.cache_read_input_tokens < 0
            || bucket.cache_read_input_tokens > bucket.input_tokens
            || bucket.input_tokens > MAX_PROMPT_SIZE_BIN_TOKENS
            || bucket.cache_read_input_tokens > MAX_PROMPT_SIZE_BIN_TOKENS
        {
            return None;
        }
        let count = i64::from(bucket.request_count);
        let (min, max) = match index {
            0 => (0_i64, 7_999_i64),
            1 => (8_000, 31_999),
            2 => (32_000, 63_999),
            3 => (64_000, 127_999),
            4 => (128_000, 255_999),
            _ => (256_000, i64::MAX),
        };
        let lower = min.checked_mul(count)?;
        let upper = (index != 5).then(|| max.checked_mul(count)).flatten();
        if bucket.input_tokens < lower || upper.is_some_and(|max| bucket.input_tokens > max) {
            return None;
        }
        input_total = input_total.checked_add(bucket.input_tokens)?;
        read_total = read_total.checked_add(bucket.cache_read_input_tokens)?;
    }
    Some((input_total, read_total))
}

/// Tracks unique requests only; any missing or contradictory request makes the result unavailable.
#[derive(Default)]
pub struct PromptSizeTracker {
    requests: HashMap<String, (i64, i64)>,
    invalid: bool,
}

impl PromptSizeTracker {
    pub fn record(&mut self, request_id: Option<&str>, input: Option<i64>, read: Option<i64>) {
        let Some(id) = request_id.filter(|id| !id.is_empty() && id.len() <= 512) else {
            self.invalid = true;
            return;
        };
        let (Some(input), Some(read)) = (input, read) else {
            self.invalid = true;
            return;
        };
        if input < 0 || read < 0 || read > input {
            self.invalid = true;
            return;
        }
        if let Some(previous) = self.requests.get(id) {
            if *previous != (input, read) {
                self.invalid = true;
            }
            return;
        }
        if self.requests.len() >= MAX_PROMPT_SIZE_REQUESTS {
            self.invalid = true;
            return;
        }
        self.requests.insert(id.to_owned(), (input, read));
    }

    pub fn invalidate(&mut self) {
        self.invalid = true;
    }

    /// Buckets are available only for complete request coverage that exactly matches turn totals.
    pub fn finish(
        self,
        expected_input: Option<i64>,
        expected_read: Option<i64>,
    ) -> Option<Vec<PromptSizeBucket>> {
        if self.invalid || self.requests.is_empty() {
            return None;
        }
        let (Some(expected_input), Some(expected_read)) = (expected_input, expected_read) else {
            return None;
        };
        if expected_input < 0 || expected_read < 0 || expected_read > expected_input {
            return None;
        }
        let mut counts = [0_u32; 6];
        let mut inputs = [0_i64; 6];
        let mut reads = [0_i64; 6];
        let mut total_input = 0_i64;
        let mut total_read = 0_i64;
        for (input, read) in self.requests.values().copied() {
            let index = bucket_for(input);
            counts[index] = counts[index].checked_add(1)?;
            inputs[index] = inputs[index].checked_add(input)?;
            reads[index] = reads[index].checked_add(read)?;
            total_input = total_input.checked_add(input)?;
            total_read = total_read.checked_add(read)?;
        }
        if (total_input, total_read) != (expected_input, expected_read) {
            return None;
        }
        let buckets: Vec<_> = (0..counts.len())
            .filter(|index| counts[*index] > 0)
            .map(|index| PromptSizeBucket {
                bucket: PROMPT_SIZE_BUCKETS[index].to_owned(),
                request_count: counts[index],
                input_tokens: inputs[index],
                cache_read_input_tokens: reads[index],
            })
            .collect();
        validate_prompt_size_buckets(&buckets).map(|_| buckets)
    }
}

/// History is forward-compatible: malformed optional bucket data is unavailable, not fatal.
pub(crate) fn deserialize_prompt_size_buckets<'de, D>(
    deserializer: D,
) -> Result<Option<Vec<PromptSizeBucket>>, D::Error>
where
    D: serde::Deserializer<'de>,
{
    let value = Option::<serde_json::Value>::deserialize(deserializer)?;
    Ok(value
        .and_then(|value| serde_json::from_value::<Vec<PromptSizeBucket>>(value).ok())
        .filter(|buckets| validate_prompt_size_buckets(buckets).is_some()))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn tracker_buckets_boundaries_and_reconciles_cache_inclusive_input() {
        let mut tracker = PromptSizeTracker::default();
        for (index, input) in [7_999, 8_000, 31_999, 32_000, 64_000, 128_000, 256_000]
            .into_iter()
            .enumerate()
        {
            tracker.record(Some(&index.to_string()), Some(input), Some(input / 2));
        }
        let sum: i64 = [7_999, 8_000, 31_999, 32_000, 64_000, 128_000, 256_000]
            .iter()
            .sum();
        let read_sum: i64 = [7_999, 8_000, 31_999, 32_000, 64_000, 128_000, 256_000]
            .iter()
            .map(|input| input / 2)
            .sum();
        let buckets = tracker.finish(Some(sum), Some(read_sum)).unwrap();
        assert_eq!(buckets.iter().map(|b| b.request_count).sum::<u32>(), 7);
        assert_eq!(buckets.iter().map(|b| b.input_tokens).sum::<i64>(), sum);
        assert_eq!(buckets[0].bucket, "under-8k");
        assert_eq!(buckets[5].bucket, "256k-plus");
    }

    #[test]
    fn missing_conflicting_overflow_and_inconsistent_coverage_are_unavailable() {
        let mut missing = PromptSizeTracker::default();
        missing.record(None, Some(10), Some(0));
        assert!(missing.finish(Some(10), Some(0)).is_none());

        let mut conflict = PromptSizeTracker::default();
        conflict.record(Some("r"), Some(10), Some(0));
        conflict.record(Some("r"), Some(11), Some(0));
        assert!(conflict.finish(Some(10), Some(0)).is_none());

        let mut mismatch = PromptSizeTracker::default();
        mismatch.record(Some("r"), Some(10), Some(0));
        assert!(mismatch.finish(Some(11), Some(0)).is_none());
        let mut overflow = PromptSizeTracker::default();
        overflow.record(Some("r1"), Some(i64::MAX), Some(0));
        overflow.record(Some("r2"), Some(i64::MAX), Some(0));
        assert!(overflow.finish(Some(i64::MAX), Some(0)).is_none());
    }

    #[test]
    fn request_tracking_stops_at_the_bound() {
        let mut tracker = PromptSizeTracker::default();
        for request in 0..=MAX_PROMPT_SIZE_REQUESTS {
            tracker.record(Some(&request.to_string()), Some(1), Some(0));
        }
        assert!(tracker
            .finish(Some(MAX_PROMPT_SIZE_REQUESTS as i64), Some(0))
            .is_none());
    }

    #[test]
    fn oversized_bin_totals_are_rejected() {
        let mut tracker = PromptSizeTracker::default();
        for request in 0..11 {
            tracker.record(Some(&request.to_string()), Some(100_000_000), Some(0));
        }
        assert!(tracker.finish(Some(1_100_000_000), Some(0)).is_none());
    }

    #[test]
    fn validator_rejects_duplicate_noncanonical_and_impossible_bins() {
        let bucket = PromptSizeBucket {
            bucket: "8k-32k".into(),
            request_count: 1,
            input_tokens: 7_999,
            cache_read_input_tokens: 0,
        };
        assert!(validate_prompt_size_buckets(&[bucket.clone()]).is_none());
        let valid = PromptSizeBucket {
            input_tokens: 8_000,
            ..bucket
        };
        assert!(validate_prompt_size_buckets(&[valid.clone(), valid]).is_none());
    }
}
