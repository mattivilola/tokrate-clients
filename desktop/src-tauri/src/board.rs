//! The community board as the UI reads it. The service's response is parsed into this typed
//! structure and only that structure is forwarded: a field of the wrong type, a missing id, an
//! oversized string or a list past its cap rejects the whole board, so nothing the UI dereferences
//! can be malformed and nothing unlisted reaches the webview.
use chrono::DateTime;
use serde::{Deserialize, Deserializer, Serialize};
use serde_json::Value;

/// The board schema the app understands.
const SCHEMA_VERSION: u64 = 1;
const MAX_COHORTS: usize = 10_000;
const MAX_ALERTS: usize = 1_000;
/// Longest string kept: a cohort id (a JSON-encoded tuple of identifiers) is the longest.
const MAX_TEXT_BYTES: usize = 2_048;
/// Error alerts kept (contract "Community error alerts (0.1.23)"); the server's order is kept.
const MAX_ERROR_ALERTS: usize = 20;
/// Longest model id, provider or client id of an error alert (the upload rules' bound).
const MAX_ID_BYTES: usize = 80;
const MAX_ALERT_CLIENTS: usize = 16;

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct Board {
    #[serde(skip_serializing)]
    schema_version: u64,
    #[serde(skip_serializing_if = "Option::is_none")]
    window: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    state: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    data_as_of: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    methodology: Option<Methodology>,
    cohorts: Vec<Cohort>,
    #[serde(skip_serializing_if = "Option::is_none")]
    alerts: Option<Vec<Alert>>,
    /// Provider error alerts. Decoded leniently, unlike the rest of the board: see `lenient_errors`.
    #[serde(
        default,
        deserialize_with = "lenient_errors",
        skip_serializing_if = "Option::is_none"
    )]
    errors: Option<BoardErrors>,
}

/// `errors` of the board: only the alerts, never empty (no alerts is no `errors`).
#[derive(Clone, Debug, Deserialize, Serialize, PartialEq)]
struct BoardErrors {
    alerts: Vec<ErrorAlert>,
}

/// A (model, provider) pair with provider failures from enough contributors in the last hour.
#[derive(Clone, Debug, Deserialize, Serialize, PartialEq)]
#[serde(rename_all = "camelCase")]
struct ErrorAlert {
    model: String,
    provider: String,
    clients: Vec<String>,
    failing_contributors: u64,
    overloaded: u64,
    server_error: u64,
    first_failure_at: String,
    last_failure_at: String,
}

impl ErrorAlert {
    /// An alert the UI can word: named, from at least one contributor, with at least one counted
    /// failure and readable times.
    fn is_sound(&self) -> bool {
        let id = |text: &str, max: usize| !text.is_empty() && text.len() <= max;
        id(&self.model, MAX_ID_BYTES)
            && id(&self.provider, MAX_ID_BYTES)
            && self.clients.len() <= MAX_ALERT_CLIENTS
            && self.clients.iter().all(|client| id(client, MAX_ID_BYTES))
            && self.failing_contributors >= 1
            && self.overloaded.saturating_add(self.server_error) >= 1
            && [&self.first_failure_at, &self.last_failure_at]
                .into_iter()
                .all(|at| DateTime::parse_from_rfc3339(at).is_ok())
    }
}

/// `errors.alerts` of the board: a missing or misshapen `errors` or `alerts` is no alerts, an
/// entry that does not fit is skipped on its own and at most `MAX_ERROR_ALERTS` are kept, so
/// nothing here can fail the decode of the board (an older server has no `errors`).
fn lenient_errors<'de, D: Deserializer<'de>>(
    deserializer: D,
) -> Result<Option<BoardErrors>, D::Error> {
    let value = Value::deserialize(deserializer)?;
    let alerts: Vec<ErrorAlert> = value
        .get("alerts")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .filter_map(|entry| serde_json::from_value::<ErrorAlert>(entry.clone()).ok())
        .filter(ErrorAlert::is_sound)
        .take(MAX_ERROR_ALERTS)
        .collect();
    Ok((!alerts.is_empty()).then_some(BoardErrors { alerts }))
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq)]
#[serde(rename_all = "camelCase")]
struct Methodology {
    #[serde(skip_serializing_if = "Option::is_none")]
    publication_mode: Option<String>,
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq)]
#[serde(rename_all = "camelCase")]
struct Cohort {
    id: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    model: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    reasoning_effort: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    client: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    provider: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    contributors: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    turns: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    throughput_turns: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    ttft_turns: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    median_throughput: Option<f64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    median_ttft_ms: Option<f64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    signals: Option<Signals>,
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq)]
struct Signals {
    #[serde(skip_serializing_if = "Option::is_none")]
    throughput: Option<Signal>,
    #[serde(skip_serializing_if = "Option::is_none")]
    ttft: Option<Signal>,
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq)]
struct Signal {
    #[serde(skip_serializing_if = "Option::is_none")]
    state: Option<String>,
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq)]
#[serde(rename_all = "camelCase")]
struct Alert {
    #[serde(skip_serializing_if = "Option::is_none")]
    cohort_id: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    message: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    metric: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    state: Option<String>,
}

fn short(text: &Option<String>) -> bool {
    text.as_ref()
        .map_or(true, |text| text.len() <= MAX_TEXT_BYTES)
}

impl Board {
    /// The board in `bytes`, or `None` when it is not the expected shape in every part.
    pub fn parse(bytes: &[u8]) -> Option<Self> {
        let board: Board = serde_json::from_slice(bytes).ok()?;
        board.is_sound().then_some(board)
    }

    fn alerts(&self) -> &[Alert] {
        self.alerts.as_deref().unwrap_or_default()
    }

    fn is_sound(&self) -> bool {
        self.schema_version == SCHEMA_VERSION
            && self.cohorts.len() <= MAX_COHORTS
            && self.alerts().len() <= MAX_ALERTS
            && [&self.window, &self.state, &self.data_as_of]
                .into_iter()
                .all(short)
            && self
                .methodology
                .as_ref()
                .map_or(true, |methodology| short(&methodology.publication_mode))
            && self.cohorts.iter().all(|cohort| {
                cohort.id.len() <= MAX_TEXT_BYTES
                    && [
                        &cohort.model,
                        &cohort.reasoning_effort,
                        &cohort.client,
                        &cohort.provider,
                    ]
                    .into_iter()
                    .all(short)
                    && cohort.signals.iter().all(|signals| {
                        [&signals.throughput, &signals.ttft]
                            .into_iter()
                            .all(|signal| signal.as_ref().map_or(true, |s| short(&s.state)))
                    })
            })
            && self.alerts().iter().all(|alert| {
                [
                    &alert.cohort_id,
                    &alert.message,
                    &alert.metric,
                    &alert.state,
                ]
                .into_iter()
                .all(short)
            })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::{json, Value};

    fn parse(value: Value) -> Option<Board> {
        Board::parse(value.to_string().as_bytes())
    }
    fn board_with(cohort: Value) -> Value {
        json!({"schemaVersion": 1, "cohorts": [cohort]})
    }

    #[test]
    fn a_well_formed_board_is_kept_and_only_the_listed_fields_are_forwarded() {
        let board = parse(json!({
            "schemaVersion": 1,
            "window": "24h",
            "state": "ok",
            "dataAsOf": "2026-10-03T10:00:00Z",
            "methodology": {"publicationMode": "early_data", "internal": "dropped"},
            "secret": "dropped",
            "cohorts": [{
                "id": "[\"m\"]", "model": "grok-4", "reasoningEffort": null, "client": "codex",
                "provider": "openai", "contributors": 4, "turns": 40, "throughputTurns": 38,
                "ttftTurns": 0, "medianThroughput": 61.5, "medianTtftMs": 840,
                "signals": {"throughput": {"state": "stable", "x": 1}, "ttft": {}},
                "extra": {"nested": true}
            }],
            "alerts": [{"cohortId": "[\"m\"]", "message": "slower", "other": 1}]
        }))
        .unwrap();
        let forwarded = serde_json::to_value(&board).unwrap();
        assert_eq!(
            forwarded,
            json!({
                "window": "24h",
                "state": "ok",
                "dataAsOf": "2026-10-03T10:00:00Z",
                "methodology": {"publicationMode": "early_data"},
                "cohorts": [{
                    "id": "[\"m\"]", "model": "grok-4", "client": "codex", "provider": "openai",
                    "contributors": 4, "turns": 40, "throughputTurns": 38, "ttftTurns": 0,
                    "medianThroughput": 61.5, "medianTtftMs": 840.0,
                    "signals": {"throughput": {"state": "stable"}, "ttft": {}}
                }],
                "alerts": [{"cohortId": "[\"m\"]", "message": "slower"}]
            })
        );
        // The smallest board is fine too.
        assert!(parse(json!({"schemaVersion": 1, "cohorts": []})).is_some());
        assert!(parse(json!({"schemaVersion": 1, "cohorts": [], "alerts": null})).is_some());
    }

    #[test]
    fn malformed_boards_are_rejected_whole() {
        let rejected: Vec<Value> = vec![
            json!({"schemaVersion": 1, "cohorts": [null]}),
            json!({"schemaVersion": 1, "cohorts": ["text"]}),
            json!({"schemaVersion": 1, "cohorts": {"id": "x"}}),
            json!({"schemaVersion": 1}),
            json!({"cohorts": []}),
            json!({"schemaVersion": 2, "cohorts": []}),
            json!({"schemaVersion": "1", "cohorts": []}),
            json!(null),
            json!([]),
            // A cohort without an id, or with the wrong type anywhere.
            board_with(json!({"model": "m"})),
            board_with(json!({"id": 7})),
            board_with(json!({"id": null})),
            board_with(json!({"id": "x", "model": 5})),
            board_with(json!({"id": "x", "contributors": "many"})),
            board_with(json!({"id": "x", "contributors": -1})),
            board_with(json!({"id": "x", "turns": 1.5})),
            board_with(json!({"id": "x", "medianThroughput": "fast"})),
            board_with(json!({"id": "x", "medianTtftMs": [1]})),
            board_with(json!({"id": "x", "signals": "stable"})),
            board_with(json!({"id": "x", "signals": {"throughput": 3}})),
            board_with(json!({"id": "x", "signals": {"ttft": {"state": 1}}})),
            json!({"schemaVersion": 1, "cohorts": [], "window": 24}),
            json!({"schemaVersion": 1, "cohorts": [], "methodology": []}),
            json!({"schemaVersion": 1, "cohorts": [], "alerts": [null]}),
            json!({"schemaVersion": 1, "cohorts": [], "alerts": {}}),
            json!({"schemaVersion": 1, "cohorts": null}),
            json!({"schemaVersion": 1, "cohorts": [], "alerts": [{"cohortId": 3}]}),
            json!({"schemaVersion": 1, "cohorts": [], "alerts": [{"message": {}}]}),
        ];
        for board in rejected {
            assert!(parse(board.clone()).is_none(), "{board}");
        }
        assert!(Board::parse(b"not json").is_none());
        assert!(Board::parse(b"").is_none());
    }

    #[test]
    fn boards_past_a_size_cap_are_rejected() {
        let long = "x".repeat(MAX_TEXT_BYTES + 1);
        assert!(parse(board_with(json!({"id": long}))).is_none());
        assert!(parse(board_with(json!({"id": "x", "model": long}))).is_none());
        assert!(parse(json!({"schemaVersion": 1, "cohorts": [], "state": long})).is_none());
        assert!(
            parse(json!({"schemaVersion": 1, "cohorts": [], "alerts": [{"message": long}]}))
                .is_none()
        );
        let at_limit = "x".repeat(MAX_TEXT_BYTES);
        assert!(parse(board_with(json!({"id": at_limit}))).is_some());
        let cohorts: Vec<Value> = (0..=MAX_COHORTS)
            .map(|i| json!({"id": i.to_string()}))
            .collect();
        assert!(parse(json!({"schemaVersion": 1, "cohorts": cohorts})).is_none());
        let alerts: Vec<Value> = (0..=MAX_ALERTS).map(|_| json!({})).collect();
        assert!(parse(json!({"schemaVersion": 1, "cohorts": [], "alerts": alerts})).is_none());
    }

    fn alert(model: &str) -> Value {
        json!({
            "model": model, "provider": "anthropic", "clients": ["claude-code"],
            "failingContributors": 3, "overloaded": 4, "serverError": 0,
            "firstFailureAt": "2026-10-13T11:10:00Z", "lastFailureAt": "2026-10-13T11:50:00Z"
        })
    }
    fn alerts_of(errors: Value) -> Vec<String> {
        let board = parse(json!({"schemaVersion": 1, "cohorts": [], "errors": errors})).unwrap();
        board
            .errors
            .map(|errors| errors.alerts.into_iter().map(|a| a.model).collect())
            .unwrap_or_default()
    }

    #[test]
    fn error_alerts_are_decoded_and_forwarded_with_the_listed_fields_only() {
        let mut entry = alert("claude-opus-5-5");
        entry["internal"] = json!("dropped");
        let board = parse(json!({
            "schemaVersion": 1, "cohorts": [], "errors": {"alerts": [entry], "extra": 1}
        }))
        .unwrap();
        assert_eq!(
            serde_json::to_value(&board).unwrap(),
            json!({"cohorts": [], "errors": {"alerts": [alert("claude-opus-5-5")]}})
        );
    }

    #[test]
    fn a_board_without_error_alerts_decodes_as_none() {
        for board in [
            json!({"schemaVersion": 1, "cohorts": []}),
            json!({"schemaVersion": 1, "cohorts": [], "errors": null}),
            json!({"schemaVersion": 1, "cohorts": [], "errors": {}}),
            json!({"schemaVersion": 1, "cohorts": [], "errors": {"alerts": []}}),
            json!({"schemaVersion": 1, "cohorts": [], "errors": {"alerts": null}}),
            json!({"schemaVersion": 1, "cohorts": [], "errors": {"alerts": {"model": "m"}}}),
            json!({"schemaVersion": 1, "cohorts": [], "errors": "broken"}),
            json!({"schemaVersion": 1, "cohorts": [], "errors": [1, 2]}),
            json!({"schemaVersion": 1, "cohorts": [], "errors": 7}),
        ] {
            let decoded = parse(board.clone()).unwrap_or_else(|| panic!("{board}"));
            assert!(decoded.errors.is_none(), "{board}");
            assert!(serde_json::to_value(&decoded)
                .unwrap()
                .get("errors")
                .is_none());
        }
    }

    #[test]
    fn a_malformed_error_alert_is_skipped_on_its_own() {
        let mut broken = vec![json!(null), json!("text"), json!(7), json!({})];
        for (field, value) in [
            ("model", json!(5)),
            ("model", json!("")),
            ("model", json!("x".repeat(MAX_ID_BYTES + 1))),
            ("provider", json!(null)),
            ("provider", json!("")),
            ("clients", json!("claude-code")),
            ("clients", json!([1])),
            ("clients", json!(["x".repeat(MAX_ID_BYTES + 1)])),
            ("clients", json!(vec!["claude-code"; MAX_ALERT_CLIENTS + 1])),
            ("failingContributors", json!(0)),
            ("failingContributors", json!(-1)),
            ("failingContributors", json!(2.5)),
            ("failingContributors", json!("3")),
            ("overloaded", json!(-1)),
            ("serverError", json!("1")),
            ("firstFailureAt", json!("yesterday")),
            ("lastFailureAt", json!(12)),
        ] {
            let mut entry = alert("broken");
            entry[field] = value;
            broken.push(entry);
        }
        let mut no_failures = alert("broken");
        no_failures["overloaded"] = json!(0);
        no_failures["serverError"] = json!(0);
        broken.push(no_failures);
        let mut missing = alert("broken");
        missing.as_object_mut().unwrap().remove("clients");
        broken.push(missing);
        let mut entries = vec![alert("first")];
        entries.extend(broken);
        entries.push(alert("last"));
        assert_eq!(alerts_of(json!({"alerts": entries})), ["first", "last"]);
        // Only broken entries is no alerts, and the rest of the board is untouched.
        let board = parse(json!({
            "schemaVersion": 1, "window": "24h", "cohorts": [{"id": "a"}],
            "errors": {"alerts": [json!(null)]}
        }))
        .unwrap();
        assert!(board.errors.is_none());
        assert_eq!(board.window.as_deref(), Some("24h"));
        assert_eq!(board.cohorts.len(), 1);
    }

    #[test]
    fn at_most_twenty_error_alerts_are_kept_in_the_servers_order() {
        let entries: Vec<Value> = (0..30).map(|i| alert(&format!("model-{i}"))).collect();
        let kept = alerts_of(json!({"alerts": entries}));
        assert_eq!(kept.len(), MAX_ERROR_ALERTS);
        assert_eq!(kept[0], "model-0");
        assert_eq!(kept[19], "model-19");
        // A skipped entry does not use up a place.
        let mut entries = vec![json!(null)];
        entries.extend((0..21).map(|i| alert(&format!("model-{i}"))));
        let kept = alerts_of(json!({"alerts": entries}));
        assert_eq!(kept.len(), MAX_ERROR_ALERTS);
        assert_eq!(kept[19], "model-19");
    }
}
