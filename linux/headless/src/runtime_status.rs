//! Local operational status only. None of these fields enter a contribution.
use chrono::{DateTime, Duration, Utc};
use serde::{Deserialize, Serialize};

#[derive(Clone, Copy, Debug, Default, PartialEq, Deserialize, Serialize)]
#[serde(rename_all = "lowercase")]
pub(crate) enum UploadState {
    #[default]
    Unknown,
    Off,
    Stopped,
    Uploading,
    Idle,
    Scheduled,
}

#[derive(Clone, Debug, Default, PartialEq, Deserialize, Serialize)]
pub(crate) struct UploadSchedule {
    pub state: UploadState,
    pub next_attempt_at: Option<DateTime<Utc>>,
}

/// Use the same retry gate as the runtime, projected from monotonic elapsed time.
/// This predicts an attempt, never network completion or publication.
pub(crate) fn upload_schedule(
    now: DateTime<Utc>,
    monitoring: bool,
    sharing: bool,
    uploading: bool,
    retry_remaining: std::time::Duration,
    ready: bool,
    eligible: Option<DateTime<Utc>>,
) -> UploadSchedule {
    let state = if !monitoring {
        UploadState::Stopped
    } else if !sharing {
        UploadState::Off
    } else if uploading {
        UploadState::Uploading
    } else {
        let earliest = if ready { Some(now) } else { eligible };
        if let Some(earliest) = earliest {
            let retry_at = now + Duration::from_std(retry_remaining).unwrap_or(Duration::MAX);
            return UploadSchedule {
                state: UploadState::Scheduled,
                next_attempt_at: Some(earliest.max(retry_at)),
            };
        }
        UploadState::Idle
    };
    UploadSchedule {
        state,
        next_attempt_at: None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::Duration as Span;

    #[test]
    fn schedule_respects_real_eligibility_and_monotonic_retry_gate() {
        let now = DateTime::parse_from_rfc3339("2026-10-16T14:00:00Z")
            .unwrap()
            .with_timezone(&Utc);
        let future = now + Duration::seconds(50);
        let schedule = |monitoring, sharing, uploading, retry, ready, eligible| {
            upload_schedule(
                now,
                monitoring,
                sharing,
                uploading,
                Span::from_secs(retry),
                ready,
                eligible,
            )
        };
        assert_eq!(
            schedule(true, true, false, 12, true, None).next_attempt_at,
            Some(now + Duration::seconds(12))
        );
        assert_eq!(
            schedule(true, true, false, 12, false, Some(future)).next_attempt_at,
            Some(future)
        );
        assert_eq!(
            schedule(true, true, false, 60, false, Some(future)).next_attempt_at,
            Some(now + Duration::seconds(60))
        );
        assert_eq!(
            schedule(true, true, false, 0, true, None).next_attempt_at,
            Some(now)
        );
        for (monitoring, sharing, uploading, state) in [
            (false, true, false, UploadState::Stopped),
            (true, false, false, UploadState::Off),
            (true, true, true, UploadState::Uploading),
        ] {
            let result = schedule(monitoring, sharing, uploading, 20, true, Some(future));
            assert_eq!(result.state, state);
            assert_eq!(result.next_attempt_at, None);
        }
        assert_eq!(
            schedule(true, true, false, 20, false, None).state,
            UploadState::Idle
        );
    }
}
