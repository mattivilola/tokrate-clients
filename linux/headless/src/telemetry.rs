//! Headless package identity with the unchanged shared serializer and signature format.
use chrono::{DateTime, Utc};
use tokrate_core::{signed_request, CoreError, SignedRequest, UploadBatch};

pub(crate) fn sign_batch(
    batch: &UploadBatch,
    key: &[u8; 32],
    now: DateTime<Utc>,
) -> Result<SignedRequest, CoreError> {
    let mut batch = batch.clone();
    for sample in &mut batch.samples {
        sample.app_version = crate::APP_VERSION;
    }
    for count in &mut batch.request_counts {
        count.app_version = crate::APP_VERSION;
    }
    signed_request(&batch.samples, &batch.request_counts, key, now)
}

pub(crate) fn example_request_json() -> String {
    let mut value: serde_json::Value = serde_json::from_str(&tokrate_core::example_request_json())
        .expect("shared synthetic example encodes JSON");
    for list in ["samples", "requestCounts"] {
        for row in value[list]
            .as_array_mut()
            .expect("shared example contains both arrays")
        {
            row["appVersion"] = crate::APP_VERSION.into();
        }
    }
    serde_json::to_string_pretty(&value).expect("synthetic example remains valid JSON")
}

#[cfg(test)]
#[path = "telemetry_tests.rs"]
mod tests;
