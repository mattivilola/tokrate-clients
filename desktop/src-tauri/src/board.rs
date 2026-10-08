//! The community board as the UI reads it. The service's response is parsed into this typed
//! structure and only that structure is forwarded: a field of the wrong type, a missing id, an
//! oversized string or a list past its cap rejects the whole board, so nothing the UI dereferences
//! can be malformed and nothing unlisted reaches the webview.
use serde::{Deserialize, Serialize};

/// The board schema the app understands.
const SCHEMA_VERSION: u64 = 1;
const MAX_COHORTS: usize = 10_000;
const MAX_ALERTS: usize = 1_000;
/// Longest string kept: a cohort id (a JSON-encoded tuple of identifiers) is the longest.
const MAX_TEXT_BYTES: usize = 2_048;

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
}
