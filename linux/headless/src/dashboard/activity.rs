use chrono::{DateTime, Duration, Utc};
use std::collections::BTreeMap;
use tokrate_core::TurnMetric;

pub(crate) const BIN_SECONDS: i64 = 5 * 60;
pub(crate) const BIN_COUNT: usize = 12;
const MAX_TOOLS: usize = 5;

#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct ToolActivity {
    pub name: String,
    pub completed_turns: usize,
    /// Twelve completion-count bins, oldest at index zero and current at index eleven.
    pub bins: [u16; BIN_COUNT],
}

pub(crate) fn tool_activity(records: &[TurnMetric], now: DateTime<Utc>) -> Vec<ToolActivity> {
    let seconds_into_current_bin = now.timestamp().rem_euclid(BIN_SECONDS);
    let start = now
        - Duration::seconds(seconds_into_current_bin)
        - Duration::nanoseconds(now.timestamp_subsec_nanos() as i64)
        - Duration::seconds((BIN_COUNT as i64 - 1) * BIN_SECONDS);
    let mut grouped: BTreeMap<String, ToolActivity> = BTreeMap::new();

    for record in records {
        if record.completed_at < start || record.completed_at > now {
            continue;
        }
        let name = tool_name(&record.client);
        let entry = grouped.entry(name.clone()).or_insert_with(|| ToolActivity {
            name,
            completed_turns: 0,
            bins: [0; BIN_COUNT],
        });
        let age_from_start = record
            .completed_at
            .signed_duration_since(start)
            .num_seconds();
        let index = (age_from_start / BIN_SECONDS).clamp(0, BIN_COUNT as i64 - 1) as usize;
        entry.completed_turns += 1;
        entry.bins[index] = entry.bins[index].saturating_add(1);
    }

    let mut activity: Vec<_> = grouped.into_values().collect();
    activity.sort_by(|a, b| {
        b.completed_turns
            .cmp(&a.completed_turns)
            .then_with(|| a.name.cmp(&b.name))
    });
    activity.truncate(MAX_TOOLS);
    activity
}

fn tool_name(client: &str) -> String {
    match client {
        "codex" | "codex-cli" => "Codex".into(),
        "claude-code" => "Claude Code".into(),
        "grok-build" => "Grok Build".into(),
        "antigravity" => "Antigravity".into(),
        "opencode" => "OpenCode".into(),
        "kimi-code" => "Kimi Code".into(),
        "kimi-desktop" => "Kimi Desktop".into(),
        "t3-code" => "T3 Code".into(),
        _ => {
            let safe: String = client
                .chars()
                .filter(|c| c.is_ascii_alphanumeric() || matches!(c, '-' | '_' | ' ' | '.'))
                .take(24)
                .collect();
            if safe.trim().is_empty() {
                "Unknown tool".into()
            } else {
                safe
            }
        }
    }
}

pub(crate) fn spark(bins: &[u16; BIN_COUNT]) -> String {
    let bars = ['·', '▁', '▂', '▃', '▄', '▅', '▆', '▇', '█'];
    let max = bins.iter().copied().max().unwrap_or(0).max(1) as f64;
    bins.iter()
        .map(|count| {
            if *count == 0 {
                bars[0]
            } else {
                let level = ((*count as f64 / max) * 8.0).ceil() as usize;
                bars[level.clamp(1, 8)]
            }
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::TimeZone;

    fn metric(client: &str, completed_at: DateTime<Utc>, model: &str) -> TurnMetric {
        let mut metric = TurnMetric::new(
            format!("{client}-{model}-{}", completed_at.timestamp()),
            completed_at,
            Some(model.into()),
            100,
            2.0,
            None,
            50.0,
            None,
            None,
            None,
            Some("primary".into()),
            Some("provider".into()),
            None,
        );
        metric.client = client.into();
        metric
    }

    #[test]
    fn completed_turn_activity_bins_are_oldest_first_and_include_exact_window_edges() {
        let now = Utc.with_ymd_and_hms(2026, 10, 16, 12, 0, 0).unwrap();
        let records = vec![
            metric("codex", now - Duration::minutes(55), "older-model"),
            metric("codex", now - Duration::minutes(50), "other-model"),
            metric("codex", now - Duration::seconds(1), "current-model"),
            metric("codex", now, "current-model"),
            metric("claude-code", now + Duration::seconds(1), "future"),
            metric("claude-code", now - Duration::minutes(56), "too-old"),
        ];
        let rows = tool_activity(&records, now);
        assert_eq!(rows.len(), 1);
        assert_eq!(rows[0].name, "Codex");
        assert_eq!(rows[0].completed_turns, 4);
        assert_eq!(rows[0].bins[0], 1);
        assert_eq!(rows[0].bins[1], 1);
        assert_eq!(rows[0].bins[10], 1);
        assert_eq!(rows[0].bins[11], 1);
        assert!(rows[0].bins[2..10].iter().all(|count| *count == 0));
        assert_eq!(spark(&rows[0].bins).chars().count(), BIN_COUNT);
    }

    #[test]
    fn tools_aggregate_models_and_sort_by_completed_turn_count() {
        let now = Utc.with_ymd_and_hms(2026, 10, 16, 12, 0, 0).unwrap();
        let records = vec![
            metric("codex", now, "gpt-one"),
            metric("codex", now - Duration::minutes(1), "gpt-two"),
            metric("claude-code", now, "opus"),
            metric("grok-build", now, "grok"),
        ];
        let rows = tool_activity(&records, now);
        assert_eq!(
            rows.iter().map(|row| row.name.as_str()).collect::<Vec<_>>(),
            ["Codex", "Claude Code", "Grok Build"]
        );
        assert_eq!(rows[0].completed_turns, 2);
        assert_eq!(rows[0].bins[10], 1);
        assert_eq!(rows[0].bins[11], 1);
    }
}
