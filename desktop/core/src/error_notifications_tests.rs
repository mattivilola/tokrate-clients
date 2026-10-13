//! Tests for the error-notification planner (contract "Error notifications (0.1.23)").

use crate::{
    ErrorNotification, ErrorNotificationKind as Kind, ErrorNotificationPlanner, RelevantErrorAlert,
};
use chrono::{DateTime, Duration, Utc};

fn start() -> DateTime<Utc> {
    DateTime::parse_from_rfc3339("2026-10-13T12:00:00Z")
        .unwrap()
        .with_timezone(&Utc)
}

fn at(minutes: i64) -> DateTime<Utc> {
    start() + Duration::minutes(minutes)
}

fn alert(model: &str) -> RelevantErrorAlert {
    RelevantErrorAlert {
        model: model.into(),
        failing_contributors: 4,
        overloaded: 6,
        server_error: 0,
        last_failure_at: start(),
        not_just_you: false,
        others: 3,
    }
}

fn summary(notifications: &[ErrorNotification]) -> Vec<(Kind, &str)> {
    notifications
        .iter()
        .map(|n| (n.kind, n.model.as_str()))
        .collect()
}

/// A planner that has taken in an empty first board, so the next boards notify.
fn running() -> ErrorNotificationPlanner {
    let mut planner = ErrorNotificationPlanner::new();
    assert!(planner.plan(&[], at(0)).is_empty());
    planner
}

#[test]
fn a_new_alert_starts_an_episode_with_one_notification() {
    let mut planner = running();
    let first = planner.plan(&[alert("m")], at(1));
    assert_eq!(summary(&first), [(Kind::Start, "m")]);
    // The alert staying does not notify again, however many boards report it.
    for minute in 2..40 {
        assert!(planner.plan(&[alert("m")], at(minute)).is_empty());
    }
}

#[test]
fn every_model_has_its_own_episode() {
    let mut planner = running();
    assert_eq!(
        summary(&planner.plan(&[alert("a"), alert("b")], at(1))),
        [(Kind::Start, "a"), (Kind::Start, "b")]
    );
    assert_eq!(
        summary(&planner.plan(&[alert("a"), alert("b"), alert("c")], at(2))),
        [(Kind::Start, "c")]
    );
    // The same model twice (two providers) is one episode.
    let mut planner = running();
    let twice = planner.plan(&[alert("a"), alert("a")], at(1));
    assert_eq!(summary(&twice), [(Kind::Start, "a")]);
}

#[test]
fn the_start_text_for_a_failure_of_the_users_own() {
    let mut planner = running();
    let mut own = alert("claude-opus-5-5");
    own.not_just_you = true;
    own.others = 3;
    let notifications = planner.plan(&[own.clone()], at(1));
    assert_eq!(notifications[0].title, "Provider errors on claude-opus-5-5");
    assert_eq!(
        notifications[0].body,
        "It’s not just you: 3 other contributors hit provider errors on this model in the last hour."
    );
    let mut planner = running();
    own.others = 1;
    assert_eq!(
        planner.plan(&[own], at(1))[0].body,
        "It’s not just you: 1 other contributor hit provider errors on this model in the last hour."
    );
}

#[test]
fn the_start_text_for_the_reports_of_contributors() {
    let body = |overloaded, server_error, contributors| {
        let mut planner = running();
        let mut a = alert("m");
        a.overloaded = overloaded;
        a.server_error = server_error;
        a.failing_contributors = contributors;
        let notifications = planner.plan(&[a], at(1));
        assert_eq!(notifications[0].title, "Provider errors on m");
        notifications[0].body.clone()
    };
    assert_eq!(
        body(6, 0, 4),
        "4 Tokrate contributors reported 6 overloaded / at capacity in the last hour."
    );
    assert_eq!(
        body(0, 1, 1),
        "1 Tokrate contributor reported 1 server error in the last hour."
    );
    assert_eq!(
        body(1, 2, 3),
        "3 Tokrate contributors reported 1 overloaded / at capacity and 2 server errors in the last hour."
    );
}

#[test]
fn the_recovery_text() {
    let mut planner = running();
    planner.plan(&[alert("gpt-5.5")], at(1));
    planner.plan(&[], at(2));
    let notifications = planner.plan(&[], at(32));
    assert_eq!(notifications.len(), 1);
    assert_eq!(notifications[0].kind, Kind::Recovery);
    assert_eq!(notifications[0].title, "gpt-5.5 looks healthy again");
    assert_eq!(
        notifications[0].body,
        "Contributors no longer report provider errors on this model."
    );
}

#[test]
fn an_episode_ends_after_thirty_minutes_without_the_alert_and_not_before() {
    let mut planner = running();
    planner.plan(&[alert("m")], at(1));
    // First absent at minute 10: it ends at minute 40.
    assert!(planner.plan(&[], at(10)).is_empty());
    assert!(planner.plan(&[], at(39)).is_empty());
    assert_eq!(summary(&planner.plan(&[], at(40))), [(Kind::Recovery, "m")]);
    // Once ended, nothing more is said, and a new alert is a new episode.
    assert!(planner.plan(&[], at(41)).is_empty());
    assert_eq!(
        summary(&planner.plan(&[alert("m")], at(42))),
        [(Kind::Start, "m")]
    );
}

#[test]
fn a_reappearance_within_the_window_continues_the_episode() {
    let mut planner = running();
    planner.plan(&[alert("m")], at(1));
    assert!(planner.plan(&[], at(5)).is_empty());
    assert!(planner.plan(&[], at(30)).is_empty());
    // Back after 29 minutes: no new start, and the absence clock starts over.
    assert!(planner.plan(&[alert("m")], at(34)).is_empty());
    assert!(planner.plan(&[], at(35)).is_empty());
    assert!(planner.plan(&[], at(64)).is_empty());
    assert_eq!(summary(&planner.plan(&[], at(65))), [(Kind::Recovery, "m")]);
}

#[test]
fn a_suppressed_start_suppresses_its_recovery() {
    let mut planner = running();
    planner.plan(&[alert("a"), alert("b"), alert("c")], at(1));
    // "d" appears while the cap is used up.
    assert!(planner.plan(&[alert("d")], at(2)).is_empty());
    // Minute 62: the hour has passed, a slot is free, but "d" was never announced. "a", "b" and
    // "c" were absent since minute 2 and end now with recoveries; "d" stays present.
    let notifications = planner.plan(&[alert("d")], at(62));
    assert_eq!(
        summary(&notifications),
        [
            (Kind::Recovery, "a"),
            (Kind::Recovery, "b"),
            (Kind::Recovery, "c")
        ]
    );
    // "d" leaves: its episode ends without a recovery.
    assert!(planner.plan(&[], at(63)).is_empty());
    assert!(planner.plan(&[], at(95)).is_empty());
}

#[test]
fn at_most_three_notifications_per_hour_in_total() {
    let mut planner = running();
    // Two starts and a recovery use the hour's three.
    assert_eq!(planner.plan(&[alert("a"), alert("b")], at(1)).len(), 2);
    assert!(planner.plan(&[alert("b")], at(2)).is_empty());
    assert_eq!(
        summary(&planner.plan(&[alert("b")], at(32))),
        [(Kind::Recovery, "a")]
    );
    // A fourth within the hour (since minute 1) is suppressed.
    assert!(planner.plan(&[alert("b"), alert("c")], at(33)).is_empty());
    // The slots of minute 1 are free from minute 61 on (the hour is exclusive).
    assert!(planner.plan(&[alert("b"), alert("e")], at(60)).is_empty());
    assert_eq!(
        summary(&planner.plan(&[alert("b"), alert("f")], at(62))),
        [(Kind::Start, "f")]
    );
}

#[test]
fn a_recovery_the_cap_suppresses_is_dropped_not_postponed() {
    let mut planner = running();
    planner.plan(&[alert("a"), alert("b"), alert("c")], at(1));
    // The three leave at minute 2 and end at minute 32, while the hour's three are still used.
    assert!(planner.plan(&[], at(2)).is_empty());
    assert!(planner.plan(&[], at(32)).is_empty());
    assert!(planner.plan(&[], at(61)).is_empty());
    assert!(planner.plan(&[], at(120)).is_empty());
}

#[test]
fn alerts_present_at_the_first_board_count_as_notified_without_posting() {
    let mut planner = ErrorNotificationPlanner::new();
    assert!(planner
        .plan(&[alert("old"), alert("older")], at(0))
        .is_empty());
    // They do not notify again, and their end is notified as it was notified before.
    assert!(planner
        .plan(&[alert("old"), alert("older")], at(1))
        .is_empty());
    assert!(planner.plan(&[alert("old")], at(2)).is_empty());
    assert_eq!(
        summary(&planner.plan(&[alert("old")], at(32))),
        [(Kind::Recovery, "older")]
    );
}

#[test]
fn a_baseline_posts_nothing_so_it_leaves_the_whole_cap_free() {
    let mut planner = ErrorNotificationPlanner::new();
    assert!(planner.plan(&[alert("old")], at(0)).is_empty());
    let alerts = [alert("old"), alert("a"), alert("b"), alert("c")];
    assert_eq!(planner.plan(&alerts, at(1)).len(), 3);
}

#[test]
fn reset_forgets_episodes_and_takes_the_next_board_as_the_baseline() {
    let mut planner = running();
    planner.plan(&[alert("m")], at(1));
    planner.reset();
    // The alert still there after sharing or the setting came back on: already notified.
    assert!(planner.plan(&[alert("m")], at(2)).is_empty());
    assert!(planner.plan(&[alert("m")], at(3)).is_empty());
    // The episode is the baseline's: its end notifies once.
    assert!(planner.plan(&[], at(4)).is_empty());
    assert_eq!(summary(&planner.plan(&[], at(34))), [(Kind::Recovery, "m")]);
}

#[test]
fn reset_keeps_the_hours_notifications_so_switching_cannot_get_around_the_cap() {
    let mut planner = running();
    planner.plan(&[alert("a"), alert("b"), alert("c")], at(1));
    planner.reset();
    assert!(planner.plan(&[], at(2)).is_empty());
    assert!(planner.plan(&[alert("x")], at(3)).is_empty());
    assert!(planner.plan(&[alert("x"), alert("y")], at(4)).is_empty());
    // Once the hour has passed the cap is free again.
    assert_eq!(
        summary(&planner.plan(&[alert("x"), alert("z")], at(62))),
        [(Kind::Start, "z")]
    );
}

#[test]
fn an_alert_back_after_boards_were_missing_for_the_whole_window_starts_a_new_episode() {
    let mut planner = running();
    planner.plan(&[alert("m")], at(1));
    assert!(planner.plan(&[], at(5)).is_empty());
    // No board for 40 minutes (fetch failures): the old episode ran out unseen, its end is not
    // announced, and the alert is a new episode.
    assert_eq!(
        summary(&planner.plan(&[alert("m")], at(45))),
        [(Kind::Start, "m")]
    );
    assert!(planner.plan(&[alert("m")], at(46)).is_empty());
}

#[test]
fn a_recovery_follows_only_for_a_model_whose_alert_is_gone_for_good() {
    let mut planner = running();
    planner.plan(&[alert("a"), alert("b")], at(1));
    // "a" leaves, "b" stays, and "a" is the only one to end.
    assert!(planner.plan(&[alert("b")], at(2)).is_empty());
    let ended = planner.plan(&[alert("b")], at(32));
    assert_eq!(summary(&ended), [(Kind::Recovery, "a")]);
}
