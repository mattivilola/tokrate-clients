//! Tests for the local provider-error summary (contract "Local provider errors (0.1.23)").

use crate::provider_errors::{
    LocalProviderErrors, ProviderErrorGroup, ProviderErrorKind, MAX_LOCAL_ERROR_GROUPS,
    MAX_SEEN_KEYS,
};
use crate::{RequestOutcome, RequestOutcomeKind};
use chrono::{DateTime, Duration, Utc};

fn time(value: &str) -> DateTime<Utc> {
    DateTime::parse_from_rfc3339(value)
        .unwrap()
        .with_timezone(&Utc)
}

fn now() -> DateTime<Utc> {
    time("2026-10-13T12:00:00Z")
}

fn outcome(
    key: &str,
    client: &'static str,
    model: &str,
    kind: RequestOutcomeKind,
    at: DateTime<Utc>,
) -> RequestOutcome {
    RequestOutcome::new(
        key.into(),
        at,
        client,
        None,
        "test-v1",
        Some(model),
        Some("provider"),
        kind,
    )
    .unwrap()
}

fn minutes_ago(minutes: i64) -> DateTime<Utc> {
    now() - Duration::minutes(minutes)
}

fn shape(groups: &[ProviderErrorGroup]) -> Vec<(&str, &str, ProviderErrorKind, usize)> {
    groups
        .iter()
        .map(|g| (g.client.as_str(), g.model.as_str(), g.kind, g.count))
        .collect()
}

use ProviderErrorKind::{Overloaded as Over, ServerError as Server, Throttled as Throttle};
use RequestOutcomeKind::{Overloaded, ServerError, Succeeded, Throttled};

#[test]
fn counts_and_latest_time_per_client_model_and_kind() {
    let mut errors = LocalProviderErrors::new();
    errors.ingest(
        &[
            outcome("a", "codex", "gpt", Overloaded, minutes_ago(30)),
            outcome("b", "codex", "gpt", Overloaded, minutes_ago(10)),
            outcome("c", "codex", "gpt", ServerError, minutes_ago(20)),
            outcome("d", "claude-code", "gpt", Overloaded, minutes_ago(40)),
        ],
        now(),
    );
    let summary = errors.summary(now());
    assert_eq!(
        shape(&summary),
        vec![
            ("codex", "gpt", Over, 2),
            ("codex", "gpt", Server, 1),
            ("claude-code", "gpt", Over, 1),
        ]
    );
    assert_eq!(summary[0].latest_at, minutes_ago(10));
}

#[test]
fn throttled_failures_are_their_own_group_and_keep_the_latest_plan_percentage() {
    let throttled = |key: &str, minutes: i64, percent: Option<u8>| {
        outcome(key, "codex", "gpt", Throttled, minutes_ago(minutes))
            .with_plan_used_percent(percent)
    };
    let mut errors = LocalProviderErrors::new();
    errors.ingest(
        &[
            // Out of order on purpose: the latest failure (10 minutes ago) decides the percentage.
            throttled("a", 10, Some(61)),
            throttled("b", 30, Some(12)),
            throttled("c", 20, None),
            outcome("d", "codex", "gpt", Overloaded, minutes_ago(40)),
        ],
        now(),
    );
    let summary = errors.summary(now());
    assert_eq!(
        shape(&summary),
        vec![("codex", "gpt", Throttle, 3), ("codex", "gpt", Over, 1)]
    );
    assert_eq!(summary[0].plan_used_percent, Some(61));
    assert_eq!(summary[0].latest_at, minutes_ago(10));
    assert_eq!(summary[1].plan_used_percent, None);
    // A later failure without a known percentage replaces it with nothing.
    errors.ingest(&[throttled("e", 1, None)], now());
    assert_eq!(errors.summary(now())[0].plan_used_percent, None);
    // The percentage reaches the webview only for throttled groups, camel-cased.
    let json = serde_json::to_value(&errors.summary(now())).unwrap();
    assert_eq!(json[0]["kind"], "throttled");
    assert!(json[0].get("planUsedPercent").is_none());
    errors.ingest(&[throttled("f", 0, Some(33))], now());
    let json = serde_json::to_value(&errors.summary(now())).unwrap();
    assert_eq!(json[0]["planUsedPercent"], 33);
    assert!(json[1].get("planUsedPercent").is_none());
}

#[test]
fn successes_are_ignored() {
    let mut errors = LocalProviderErrors::new();
    errors.ingest(
        &[outcome("a", "codex", "gpt", Succeeded, minutes_ago(1))],
        now(),
    );
    assert!(errors.summary(now()).is_empty());
}

#[test]
fn groups_are_ordered_most_recent_failure_first() {
    let mut errors = LocalProviderErrors::new();
    errors.ingest(
        &[
            outcome("a", "codex", "old", Overloaded, minutes_ago(300)),
            outcome("b", "opencode", "new", ServerError, minutes_ago(2)),
            outcome("c", "kimi-code", "mid", Overloaded, minutes_ago(60)),
            outcome("d", "codex", "old", Overloaded, minutes_ago(200)),
        ],
        now(),
    );
    let models: Vec<String> = errors.summary(now()).into_iter().map(|g| g.model).collect();
    assert_eq!(models, ["new", "mid", "old"]);
}

#[test]
fn failures_expire_after_24_hours() {
    let mut errors = LocalProviderErrors::new();
    // Older than the window when it arrives: never counted.
    errors.ingest(
        &[outcome(
            "stale",
            "codex",
            "gpt",
            Overloaded,
            now() - Duration::hours(24) - Duration::seconds(1),
        )],
        now(),
    );
    assert!(errors.summary(now()).is_empty());
    errors.ingest(
        &[
            outcome(
                "early",
                "codex",
                "gpt",
                Overloaded,
                now() - Duration::hours(23),
            ),
            outcome(
                "late",
                "codex",
                "gpt",
                Overloaded,
                now() - Duration::hours(1),
            ),
        ],
        now(),
    );
    assert_eq!(shape(&errors.summary(now())), [("codex", "gpt", Over, 2)]);
    // The earlier failure ages out first: the count drops, the group stays.
    let later = now() + Duration::hours(2);
    assert_eq!(shape(&errors.summary(later)), [("codex", "gpt", Over, 1)]);
    errors.prune(later);
    assert_eq!(shape(&errors.summary(later)), [("codex", "gpt", Over, 1)]);
    // Then the group goes.
    let much_later = now() + Duration::hours(24);
    assert!(errors.summary(much_later).is_empty());
    errors.prune(much_later);
    assert!(errors.summary(much_later).is_empty());
    assert!(errors.groups.is_empty());
    assert!(errors.seen.is_empty() && errors.seen_order.is_empty());
}

#[test]
fn an_outcome_seen_before_is_not_counted_again() {
    let mut errors = LocalProviderErrors::new();
    let failure = outcome("same", "codex", "gpt", Overloaded, minutes_ago(5));
    errors.ingest(&[failure.clone(), failure.clone()], now());
    errors.ingest(&[failure], now() + Duration::minutes(1));
    assert_eq!(shape(&errors.summary(now())), [("codex", "gpt", Over, 1)]);
}

#[test]
fn the_dedupe_memory_is_bounded() {
    let mut errors = LocalProviderErrors::new();
    let batch: Vec<RequestOutcome> = (0..25_000)
        .map(|i| outcome(&format!("k{i}"), "codex", "gpt", Overloaded, minutes_ago(1)))
        .collect();
    errors.ingest(&batch, now());
    assert!(errors.seen.len() <= MAX_SEEN_KEYS);
    assert_eq!(errors.seen.len(), errors.seen_order.len());
}

#[test]
fn at_most_200_groups_are_kept_and_the_oldest_go_first() {
    let mut errors = LocalProviderErrors::new();
    // Model m0 has the newest failure, m249 the oldest.
    let batch: Vec<RequestOutcome> = (0..250)
        .map(|i| {
            outcome(
                &format!("k{i}"),
                "codex",
                &format!("m{i}"),
                Overloaded,
                minutes_ago(i + 1),
            )
        })
        .collect();
    errors.ingest(&batch, now());
    let summary = errors.summary(now());
    assert_eq!(summary.len(), MAX_LOCAL_ERROR_GROUPS);
    assert_eq!(summary[0].model, "m0");
    assert_eq!(summary[MAX_LOCAL_ERROR_GROUPS - 1].model, "m199");
    // A newer failure of a new group evicts the oldest group; an older one is not kept.
    errors.ingest(
        &[
            outcome("new", "codex", "fresh", ServerError, minutes_ago(0)),
            outcome("older", "codex", "ancient", ServerError, minutes_ago(1_000)),
        ],
        now(),
    );
    let summary = errors.summary(now());
    assert_eq!(summary.len(), MAX_LOCAL_ERROR_GROUPS);
    assert_eq!(summary[0].model, "fresh");
    assert!(summary
        .iter()
        .all(|g| g.model != "m199" && g.model != "ancient"));
    // A known group keeps counting while full.
    errors.ingest(
        &[outcome("again", "codex", "m0", Overloaded, minutes_ago(0))],
        now(),
    );
    assert_eq!(errors.summary(now())[0].count, 1);
    assert_eq!(
        errors
            .summary(now())
            .iter()
            .find(|g| g.model == "m0")
            .unwrap()
            .count,
        2
    );
}

#[test]
fn a_future_timestamp_counts_as_now() {
    let mut errors = LocalProviderErrors::new();
    errors.ingest(
        &[outcome(
            "f",
            "codex",
            "gpt",
            Overloaded,
            now() + Duration::days(30),
        )],
        now(),
    );
    let summary = errors.summary(now());
    assert_eq!(summary[0].latest_at, now());
    assert!(errors.summary(now() + Duration::hours(25)).is_empty());
}

#[test]
fn the_summary_serializes_without_any_error_text() {
    let mut errors = LocalProviderErrors::new();
    errors.ingest(
        &[outcome("a", "codex", "gpt", ServerError, minutes_ago(3))],
        now(),
    );
    let json = serde_json::to_value(errors.summary(now())).unwrap();
    assert_eq!(
        json,
        serde_json::json!([{
            "client": "codex",
            "model": "gpt",
            "kind": "serverError",
            "count": 1,
            "latestAt": "2026-10-13T11:57:00Z"
        }])
    );
}
