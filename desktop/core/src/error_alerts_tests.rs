//! Tests for the relevant-alert selection (contract "Community error alerts (0.1.23)").

use crate::error_alerts::{relevant_error_alerts, CommunityErrorAlert, MAX_ERROR_ALERTS};
use crate::{ProviderErrorGroup, ProviderErrorKind, TurnMetric};
use chrono::{DateTime, Duration, Utc};

fn now() -> DateTime<Utc> {
    DateTime::parse_from_rfc3339("2026-10-13T12:00:00Z")
        .unwrap()
        .with_timezone(&Utc)
}

fn alert(model: &str, contributors: u64) -> CommunityErrorAlert {
    CommunityErrorAlert {
        model: model.into(),
        failing_contributors: contributors,
        overloaded: 4,
        server_error: 1,
        last_failure_at: now() - Duration::minutes(3),
    }
}

fn turn(model: Option<&str>, age: Duration) -> TurnMetric {
    TurnMetric::new(
        format!("turn-{}", age.num_seconds()),
        now() - age,
        model.map(str::to_owned),
        200,
        10.0,
        None,
        20.0,
        None,
        None,
        None,
        None,
        None,
        None,
    )
}

fn failure(model: &str, age: Duration) -> ProviderErrorGroup {
    ProviderErrorGroup {
        client: "claude-code".into(),
        model: model.into(),
        kind: ProviderErrorKind::Overloaded,
        count: 1,
        latest_at: now() - age,
    }
}

fn models(selected: &[crate::RelevantErrorAlert]) -> Vec<&str> {
    selected.iter().map(|a| a.model.as_str()).collect()
}

#[test]
fn only_models_used_in_the_last_seven_days_or_failed_in_the_last_24_hours_are_relevant() {
    let alerts = [
        alert("used", 3),
        alert("used-long-ago", 3),
        alert("failed", 3),
        alert("failed-long-ago", 3),
        alert("unknown-to-me", 3),
        alert("used-by-prefix", 3),
    ];
    let history = [
        turn(Some("used"), Duration::days(6)),
        turn(
            Some("used-long-ago"),
            Duration::days(7) + Duration::seconds(1),
        ),
        // A different model id is not the same model, and a turn without one marks none.
        turn(Some("used-by-prefix-2"), Duration::hours(1)),
        turn(None, Duration::hours(1)),
        turn(Some(""), Duration::hours(1)),
    ];
    let failures = [
        failure("failed", Duration::hours(23)),
        failure(
            "failed-long-ago",
            Duration::hours(24) + Duration::seconds(1),
        ),
    ];
    let selected = relevant_error_alerts(&alerts, &history, &failures, now());
    assert_eq!(models(&selected), ["used", "failed"]);
    assert!(selected.iter().all(|a| !a.not_just_you));
    assert!(relevant_error_alerts(&[], &history, &failures, now()).is_empty());
    assert!(relevant_error_alerts(&alerts, &[], &[], now()).is_empty());
}

#[test]
fn a_failure_in_the_last_hour_puts_the_alert_first_and_counts_the_others() {
    let alerts = [alert("a", 3), alert("b", 4), alert("c", 2), alert("d", 5)];
    let history = [
        turn(Some("a"), Duration::hours(1)),
        turn(Some("b"), Duration::hours(1)),
        turn(Some("c"), Duration::hours(1)),
        turn(Some("d"), Duration::hours(1)),
    ];
    // "c" and "d" failed in the last hour (the boundary included), "b" only earlier today.
    let failures = [
        failure("c", Duration::minutes(10)),
        failure("d", Duration::hours(1)),
        failure("b", Duration::hours(2)),
    ];
    let selected = relevant_error_alerts(&alerts, &history, &failures, now());
    assert_eq!(models(&selected), ["c", "d", "a", "b"]);
    assert_eq!(
        selected
            .iter()
            .map(|a| (a.not_just_you, a.others))
            .collect::<Vec<_>>(),
        [(true, 1), (true, 4), (false, 2), (false, 3)]
    );
    assert_eq!(selected[2].failing_contributors, 3);
    assert_eq!(selected[2].overloaded, 4);
    assert_eq!(selected[2].server_error, 1);
    assert_eq!(selected[2].last_failure_at, now() - Duration::minutes(3));
}

#[test]
fn the_users_own_report_alone_is_skipped() {
    let alerts = [alert("mine", 1), alert("shared", 2), alert("quiet", 1)];
    let history = [
        turn(Some("mine"), Duration::hours(1)),
        turn(Some("shared"), Duration::hours(1)),
        turn(Some("quiet"), Duration::hours(1)),
    ];
    let failures = [
        failure("mine", Duration::minutes(5)),
        failure("shared", Duration::minutes(5)),
    ];
    let selected = relevant_error_alerts(&alerts, &history, &failures, now());
    // "mine" has only the user as a contributor; "quiet" has one contributor but not the user.
    assert_eq!(models(&selected), ["shared", "quiet"]);
    assert_eq!(selected[0].others, 1);
    assert_eq!(selected[1].others, 0);
    // The same single-contributor alert is kept when the user's failure is older than an hour.
    let older = [failure("mine", Duration::hours(3))];
    assert_eq!(
        models(&relevant_error_alerts(
            &alerts[..1],
            &history,
            &older,
            now()
        )),
        ["mine"]
    );
}

#[test]
fn the_same_model_from_two_providers_keeps_both_in_the_servers_order() {
    let alerts = [alert("m", 3), alert("other", 3), alert("m", 5)];
    let history = [turn(Some("m"), Duration::hours(1))];
    let selected = relevant_error_alerts(&alerts, &history, &[], now());
    assert_eq!(models(&selected), ["m", "m"]);
    assert_eq!(selected[1].failing_contributors, 5);
}

#[test]
fn at_most_twenty_alerts_are_read() {
    let alerts: Vec<_> = (0..30).map(|i| alert(&format!("m{i}"), 3)).collect();
    let history: Vec<_> = (0..30)
        .map(|i| turn(Some(&format!("m{i}")), Duration::minutes(i + 1)))
        .collect();
    let selected = relevant_error_alerts(&alerts, &history, &[], now());
    assert_eq!(selected.len(), MAX_ERROR_ALERTS);
    assert_eq!(selected[19].model, "m19");
}

#[test]
fn a_future_failure_or_turn_counts_as_recent() {
    let alerts = [alert("m", 3), alert("n", 3)];
    let history = [turn(Some("m"), -Duration::minutes(5))];
    let failures = [failure("n", -Duration::minutes(5))];
    let selected = relevant_error_alerts(&alerts, &history, &failures, now());
    assert_eq!(models(&selected), ["n", "m"]);
    assert!(selected[0].not_just_you);
}

#[test]
fn the_selection_serializes_for_the_webview() {
    let alerts = [alert("m", 3)];
    let history = [turn(Some("m"), Duration::hours(1))];
    let selected = relevant_error_alerts(&alerts, &history, &[], now());
    assert_eq!(
        serde_json::to_value(&selected).unwrap(),
        serde_json::json!([{
            "model": "m",
            "failingContributors": 3,
            "overloaded": 4,
            "serverError": 1,
            "lastFailureAt": "2026-10-13T11:57:00Z",
            "notJustYou": false,
            "others": 2
        }])
    );
}
