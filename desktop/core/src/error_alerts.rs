//! Which community error alerts concern the user (contract "Community error alerts (0.1.23)"):
//! the one selection behind the dashboard's community line and the operating-system
//! notifications. Pure: the caller supplies the alerts, the local history and the local provider
//! failures.

use crate::model::TurnMetric;
use crate::provider_errors::ProviderErrorGroup;
use chrono::{DateTime, Duration, Utc};
use serde::Serialize;
use std::collections::HashSet;

/// At most this many alerts are read from the board.
pub const MAX_ERROR_ALERTS: usize = 20;
/// An alert concerns the user when they used its model within this many days.
const USED_WITHIN_DAYS: i64 = 7;
/// An alert also concerns the user after a local provider failure on its model within this many
/// hours (`LOCAL_ERROR_WINDOW_HOURS`).
const FAILED_WITHIN_HOURS: i64 = crate::provider_errors::LOCAL_ERROR_WINDOW_HOURS;

/// An entry of `errors.alerts` of the community board, as far as the selection needs it.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct CommunityErrorAlert {
    pub model: String,
    pub failing_contributors: u64,
    pub overloaded: u64,
    pub server_error: u64,
    pub last_failure_at: DateTime<Utc>,
}

/// An alert that concerns the user, with the form in which it is worded.
#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct RelevantErrorAlert {
    pub model: String,
    pub failing_contributors: u64,
    pub overloaded: u64,
    pub server_error: u64,
    pub last_failure_at: DateTime<Utc>,
    /// The user had a provider failure on this model in the last hour, so the alert reads "It's
    /// not just you" and counts the other contributors.
    pub not_just_you: bool,
    /// The other contributors besides the user, whose own counts may be among the alert's.
    pub others: u64,
}

/// The alerts that concern the user, most relevant first: an alert is relevant when its model is
/// one the user used in the last 7 days (a turn of that exact model id in `history`) or had a
/// provider failure on in the last 24 hours; those with a failure in the last hour come first,
/// then the server's order stands. An alert whose model the user failed on in the last hour but
/// that no other contributor reported is only the user's own report and is left out.
pub fn relevant_error_alerts(
    alerts: &[CommunityErrorAlert],
    history: &[TurnMetric],
    failures: &[ProviderErrorGroup],
    now: DateTime<Utc>,
) -> Vec<RelevantErrorAlert> {
    if alerts.is_empty() {
        return Vec::new();
    }
    let used: HashSet<&str> = history
        .iter()
        .filter(|turn| now - turn.completed_at <= Duration::days(USED_WITHIN_DAYS))
        .filter_map(|turn| turn.model.as_deref())
        .filter(|model| !model.is_empty())
        .collect();
    let mut failed_24h = HashSet::new();
    let mut failed_hour = HashSet::new();
    for group in failures {
        let age = now - group.latest_at;
        if age <= Duration::hours(FAILED_WITHIN_HOURS) {
            failed_24h.insert(group.model.as_str());
        }
        if age <= Duration::hours(1) {
            failed_hour.insert(group.model.as_str());
        }
    }
    let relevant = alerts
        .iter()
        .take(MAX_ERROR_ALERTS)
        .filter(|alert| {
            used.contains(alert.model.as_str()) || failed_24h.contains(alert.model.as_str())
        })
        .map(|alert| RelevantErrorAlert {
            model: alert.model.clone(),
            failing_contributors: alert.failing_contributors,
            overloaded: alert.overloaded,
            server_error: alert.server_error,
            last_failure_at: alert.last_failure_at,
            not_just_you: failed_hour.contains(alert.model.as_str()),
            others: alert.failing_contributors.saturating_sub(1),
        })
        // With a failure of the user's in the last hour and nobody else counted, the alert is
        // only their own report: it is skipped, not worded as a report of contributors.
        .filter(|alert| !alert.not_just_you || alert.others >= 1);
    let (mut ordered, rest): (Vec<_>, Vec<_>) = relevant.partition(|alert| alert.not_just_you);
    ordered.extend(rest);
    ordered
}
