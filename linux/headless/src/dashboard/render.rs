use super::*;

pub(super) fn render_at(
    status: &Value,
    records: &[TurnMetric],
    cols: usize,
    rows: usize,
    demo: bool,
    now: DateTime<Utc>,
) -> String {
    if cols >= 72 && rows >= 34 {
        render_full(status, records, cols, rows, demo, now)
    } else {
        render_compact(status, records, cols, rows, demo, now)
    }
}

fn mode(status: &Value, now: DateTime<Utc>, demo: bool) -> (&'static str, Heartbeat) {
    let heartbeat = heartbeat(status, now);
    let label = if demo {
        "DEMO / SYNTHETIC DATA"
    } else {
        match heartbeat {
            Heartbeat::Stale { .. } => "HEARTBEAT STALE · VALUES FROZEN",
            Heartbeat::ClockAhead { .. } => "CLOCK AHEAD · STATUS IN FUTURE",
            Heartbeat::Fresh { .. } if status["monitoring"].as_bool() == Some(true) => {
                "LOCAL COLLECTOR / LIVE"
            }
            Heartbeat::Fresh { .. } => "COLLECTOR STOPPED",
            Heartbeat::Unknown => "HEARTBEAT UNKNOWN",
        }
    };
    (label, heartbeat)
}

fn heartbeat_line(status: &Value, heartbeat: Heartbeat) -> String {
    let uptime = uptime_seconds(status, heartbeat)
        .map(format_duration)
        .unwrap_or_else(|| "unknown".into());
    match heartbeat {
        Heartbeat::Fresh { age_seconds } => parse_time(&status["updated_at"])
            .map(|at| {
                format!(
                    "Updated {} UTC · heartbeat {} · uptime {}{}",
                    at.format("%Y-%m-%d %H:%M:%S"),
                    if age_seconds <= 5 {
                        "just now".into()
                    } else {
                        format!("{age_seconds}s ago")
                    },
                    uptime,
                    if status["monitoring"].as_bool() == Some(true) {
                        ""
                    } else {
                        " (frozen)"
                    }
                )
            })
            .unwrap_or_else(|| format!("Heartbeat unavailable · uptime {uptime}")),
        Heartbeat::Stale { age_seconds } => parse_time(&status["updated_at"])
            .map(|at| {
                format!(
                    "Last heartbeat {} UTC · {age_seconds}s old · uptime frozen at {uptime}",
                    at.format("%Y-%m-%d %H:%M:%S")
                )
            })
            .unwrap_or_else(|| "Stale heartbeat · uptime frozen".into()),
        Heartbeat::ClockAhead { seconds } => {
            format!("Heartbeat timestamp is {seconds}s in the future · uptime frozen at {uptime}")
        }
        Heartbeat::Unknown => format!("Heartbeat unavailable · uptime {uptime}"),
    }
}

fn latest_turn_line(
    status: &Value,
    records: &[TurnMetric],
    now: DateTime<Utc>,
    demo: bool,
) -> String {
    let at = parse_time(&status["latest_turn"]["completed_at"])
        .filter(|at| *at <= now)
        .or_else(|| {
            records
                .iter()
                .map(|record| record.completed_at)
                .filter(|at| *at <= now)
                .max()
        });
    let label = if demo {
        "Demo local turn"
    } else {
        "Latest local turn"
    };
    at.map(|at| {
        format!(
            "{label}: {} UTC · {}",
            at.format("%Y-%m-%d %H:%M:%S"),
            relative_age(at, now)
        )
    })
    .unwrap_or_else(|| format!("{label}: no completed turns recorded"))
}

fn hero_line(status: &Value) -> String {
    let hero = &status["hero"];
    let label = clean(
        hero["label"]
            .as_str()
            .unwrap_or("Waiting for a supported coding-tool observation"),
    );
    let speed = hero["speed"]
        .as_f64()
        .filter(|value| value.is_finite() && *value >= 0.0)
        .map(|value| format!("{value:.1} tok/s"))
        .unwrap_or_else(|| "Waiting for data".into());
    format!("{label} · {speed} · {}", text(hero, "model"))
}

fn sharing_line(status: &Value, demo: bool) -> String {
    let sharing = if status["sharing_active"].as_bool() == Some(true) {
        "ON"
    } else {
        "OFF"
    };
    format!(
        "{}SHARING {sharing} · queued {} samples + {} counts · sent {} since restart",
        if demo { "DEMO · " } else { "" },
        count(status, "pending_samples"),
        count(status, "pending_request_counts"),
        count(status, "uploaded_samples")
    )
}

fn upload_success_line(status: &Value, now: DateTime<Utc>, demo: bool) -> String {
    format!(
        "Last successful upload: {}",
        if demo {
            "Unavailable in offline demo".into()
        } else {
            last_successful_upload(status, now)
        }
    )
}

fn upload_attempt_line(status: &Value, now: DateTime<Utc>, demo: bool) -> String {
    format!(
        "Latest upload attempt: {}",
        latest_upload_attempt(status, now, demo)
    )
}

fn source_line(status: &Value) -> String {
    format!(
        "Sources: {}{}",
        text(status, "source_summary"),
        if status["source_error"].as_bool() == Some(true) {
            " / READ ERROR"
        } else {
            ""
        }
    )
}

fn compact_update_line(status: &Value, demo: bool) -> String {
    if demo {
        return "Updates disabled in offline demo".into();
    }
    let state = status["update_check"]["state"]
        .as_str()
        .unwrap_or("never-checked");
    let version = status["update_check"]["availableVersion"]
        .as_str()
        .unwrap_or("unknown");
    match state {
        "available" => format!("Update {version} available · [U] update"),
        "up-to-date" => "Up to date · [U] check".into(),
        "stale" => "Update check stale · [U] refresh".into(),
        "error" => "Update check failed · [U] retry".into(),
        _ => "Update not checked · [U] check".into(),
    }
}

pub(super) fn activity_lines(
    status: &Value,
    records: &[TurnMetric],
    now: DateTime<Utc>,
) -> Vec<String> {
    let mut lines = vec![format!(
        "{WHITE}COMPLETED TURN ACTIVITY · LOCAL HISTORY{RESET}",
    )];
    lines.push(format!(
        "{MUTED}About 55–60m · 12 × 5m bins · current partial · oldest → newest{RESET}",
    ));
    if status["history_error"].as_bool() == Some(true) {
        lines.push(format!(
            "{MUTED}Local history unavailable (read error).{RESET}"
        ));
        return lines;
    }
    let rows = tool_activity(records, now);
    if rows.is_empty() {
        let collector_available = status["monitoring"].as_bool() == Some(true)
            && matches!(heartbeat(status, now), Heartbeat::Fresh { .. });
        let empty = if !collector_available {
            "Collector unavailable or stopped · no recent activity sample."
        } else if count(status, "history_turns") == 0 {
            "No local turn history yet; no activity sample."
        } else {
            "No completed turns in these recent bins (local history)."
        };
        lines.push(format!("{MUTED}{empty}{RESET}"));
        return lines;
    }
    for row in rows {
        lines.push(format!(
            "{TEAL}▸ {WHITE}{:<15} {CORAL}{}{MUTED} · {} completed turns{RESET}",
            clean(&row.name),
            activity_spark(&row.bins),
            row.completed_turns
        ));
    }
    lines
}

fn model_lines(records: &[TurnMetric], now: DateTime<Utc>, max_models: usize) -> Vec<String> {
    let recent: Vec<_> = records
        .iter()
        .filter(|metric| {
            metric.completed_at <= now && metric.completed_at >= now - Duration::hours(24)
        })
        .collect();
    let mut lines = vec![format!(
        "{WHITE}YOUR MODELS{RESET}   {MUTED}24h medians · RSP response / TURN whole-turn"
    )];
    let mut groups: BTreeMap<String, Vec<&TurnMetric>> = BTreeMap::new();
    for metric in &recent {
        let key = json!([
            metric.client,
            metric.client_version,
            metric.parser_version,
            metric.metric_version,
            metric.model,
            metric.provider,
            metric.provider_region,
            metric.reasoning_effort,
            metric.source_kind
        ])
        .to_string();
        groups.entry(key).or_default().push(metric);
    }
    let mut groups: Vec<_> = groups.values().collect();
    groups.sort_by_key(|group| std::cmp::Reverse(group[0].completed_at));
    for group in groups.into_iter().take(max_models) {
        let newest = group[0];
        let mut response_values: Vec<f64> = group
            .iter()
            .filter_map(|metric| {
                metric
                    .plausible_response_timing()
                    .map(|(tokens, seconds, _)| tokens as f64 / seconds)
            })
            .collect();
        let response = !response_values.is_empty();
        if !response {
            response_values = group
                .iter()
                .filter(|metric| metric.output_tokens >= 20)
                .map(|metric| metric.turn_throughput_tps)
                .collect();
        }
        let trend = value_spark(&response_values);
        let mut rsp = response_values;
        let value = median(&mut rsp)
            .map(|value| format!("{value:>6.1}"))
            .unwrap_or("     —".into());
        let mut ttft: Vec<_> = group
            .iter()
            .filter_map(|metric| metric.codex_ttft_seconds)
            .collect();
        let first = median(&mut ttft)
            .map(|value| format!("{value:.2}s"))
            .unwrap_or("—".into());
        lines.push(format!(
            "{TEAL}▸ {WHITE}{:<22} {CORAL}{value} {MUTED}{}  {TEAL}{}{RESET}",
            clean(newest.model.as_deref().unwrap_or("unknown")),
            if response { "RSP" } else { "TURN" },
            if trend.is_empty() { "—" } else { &trend }
        ));
        lines.push(format!(
            "{MUTED}  {} / {} / {} / {} · {} turns · first token {}{RESET}",
            clean(&newest.client),
            clean(newest.provider.as_deref().unwrap_or("unknown")),
            clean(
                newest
                    .reasoning_effort
                    .as_deref()
                    .unwrap_or("unknown effort")
            ),
            clean(newest.source_kind.as_deref().unwrap_or("unknown source")),
            group.len(),
            first
        ));
    }
    if recent.is_empty() {
        lines.push(format!(
            "{MUTED}  No completed turns in the last 24 hours.{RESET}"
        ));
    }
    lines
}

fn framed_line(content: &str, inner: usize) -> String {
    format!(
        "{TEAL}│{RESET} {}{RESET} {TEAL}│{RESET}",
        fit(content, inner)
    )
}

fn render_full(
    status: &Value,
    records: &[TurnMetric],
    cols: usize,
    rows: usize,
    demo: bool,
    now: DateTime<Utc>,
) -> String {
    let (mode, heartbeat) = mode(status, now, demo);
    let box_width = cols.min(110);
    let inner = box_width.saturating_sub(4);
    let hero = &status["hero"];
    let speed = hero["speed"]
        .as_f64()
        .filter(|value| value.is_finite() && *value >= 0.0);
    let mut content = vec![
        format!("{WHITE}\x1b[1mT O K R A T E{RESET}  {MUTED}SERVER COMPANION{RESET}  {TEAL}{mode}"),
        format!(
            "{MUTED}{} · {} · {} UTC",
            clean(&std::env::var("HOSTNAME").unwrap_or_else(|_| "debian-server".into())),
            std::env::consts::ARCH,
            now.format("%H:%M:%S")
        ),
        format!("{MUTED}{}{RESET}", heartbeat_line(status, heartbeat)),
        format!(
            "{MUTED}{}{RESET}",
            latest_turn_line(status, records, now, demo)
        ),
        format!(
            "{MUTED}{}{RESET}",
            clean(
                hero["label"]
                    .as_str()
                    .unwrap_or("Waiting for a supported coding-tool observation")
            )
        ),
    ];
    let big = big_number(
        &speed
            .map(|value| format!("{value:.1}"))
            .unwrap_or("---".into()),
    );
    let details = [
        format!("{WHITE}{}", text(hero, "model")),
        format!("{MUTED}{} / {}", text(hero, "tool"), text(hero, "provider")),
        format!("{TEAL}tok/s"),
        format!("{MUTED}Measured from local logs"),
        format!("{MUTED}No prompts. No code. No account."),
    ];
    for (index, digits) in big.iter().enumerate() {
        let expanded: String = digits
            .chars()
            .flat_map(|character| [character, character])
            .collect();
        content.push(format!("{TEAL}{}   {}", fit(&expanded, 36), details[index]));
    }

    let recent: Vec<_> = records
        .iter()
        .filter(|metric| {
            metric.completed_at <= now && metric.completed_at >= now - Duration::hours(24)
        })
        .collect();
    let tokens: i64 = recent.iter().map(|metric| metric.output_tokens).sum();
    content.push(format!(
        "{WHITE}{} {MUTED}turns / 24h     {WHITE}{:.1}k {MUTED}output tokens     {WHITE}{} {MUTED}stored / 7d",
        recent.len(),
        tokens as f64 / 1000.0,
        count(status, "history_turns")
    ));
    content.push(format!("{MUTED}{}", "─".repeat(inner)));
    content.extend(model_lines(records, now, 2));
    content.extend(activity_lines(status, records, now));
    content.push(format!("{MUTED}{}", "─".repeat(inner)));
    content.push(format!("{TEAL}● {}{RESET}", sharing_line(status, demo)));
    content.push(format!(
        "{MUTED}{}{RESET}",
        upload_success_line(status, now, demo)
    ));
    content.push(format!(
        "{MUTED}{}{RESET}",
        upload_attempt_line(status, now, demo)
    ));
    content.push(format!(
        "{MUTED}{}{}{RESET}",
        if demo { "DEMO · " } else { "" },
        schedule_line(status, heartbeat, now, demo)
    ));
    content.push(format!("{MUTED}{}{RESET}", source_line(status)));
    content.push(format!("{MUTED}{}{RESET}", update_line(status, demo)));
    content.push(format!(
        "{} {CORAL}[Q] / [ESC]{RESET} {MUTED}back to shell · collector keeps running     {TEAL}tokrate.dev",
        if demo {
            format!("{MUTED}Updates disabled in offline demo")
        } else {
            format!("{CORAL}[U]{RESET} {MUTED}update")
        }
    ));

    let body_capacity = rows.saturating_sub(2);
    if content.len() > body_capacity {
        // The full design is intentionally chosen only above its minimum height. If future
        // sections grow, trim optional activity rows before touching status and upload rows.
        let activity_start = content
            .iter()
            .position(|line| line.contains("COMPLETED TURN ACTIVITY"));
        if let Some(start) = activity_start {
            let mut activity_end = content[start..]
                .iter()
                .position(|line| line.contains("────"))
                .map(|offset| start + offset)
                .unwrap_or(content.len());
            while content.len() > body_capacity && activity_end > start + 3 {
                content.remove(activity_end - 1);
                activity_end -= 1;
            }
        }
        content.truncate(body_capacity);
    }
    let mut lines = vec![format!("{TEAL}╭{}╮{RESET}", "─".repeat(box_width - 2))];
    lines.extend(content.iter().map(|line| framed_line(line, inner)));
    lines.push(format!("{TEAL}╰{}╯{RESET}", "─".repeat(box_width - 2)));
    lines.join("\r\n") + "\r\n"
}

fn render_compact(
    status: &Value,
    records: &[TurnMetric],
    cols: usize,
    rows: usize,
    demo: bool,
    now: DateTime<Utc>,
) -> String {
    let (mode, heartbeat) = mode(status, now, demo);
    let width = cols.max(1);
    let mut lines = vec![
        format!("{TEAL}T O K R A T E{RESET} · {WHITE}{mode}{RESET}"),
        format!("{MUTED}{}{RESET}", heartbeat_line(status, heartbeat)),
        format!("{CORAL}{}{RESET}", hero_line(status)),
    ];

    if rows >= 12 {
        lines.push(format!(
            "{MUTED}{}{RESET}",
            latest_turn_line(status, records, now, demo)
        ));
    }
    let mut optional = activity_lines(status, records, now);
    let fixed_rows = lines.len() + if rows >= 9 { 6 } else { 5 } + usize::from(rows >= 17);
    let remaining = rows.saturating_sub(fixed_rows);
    if remaining >= 3 {
        let max_tool_rows = remaining
            .saturating_sub(2)
            .min(activity_tool_rows(&optional));
        optional.truncate(2 + max_tool_rows.max(if optional.len() == 3 { 1 } else { 0 }));
        lines.extend(optional);
    }

    lines.push(format!("{TEAL}{}{RESET}", sharing_line(status, demo)));
    lines.push(format!(
        "{MUTED}{}{RESET}",
        schedule_line(status, heartbeat, now, demo)
    ));
    lines.push(format!(
        "{MUTED}{}{RESET}",
        upload_success_line(status, now, demo)
    ));
    lines.push(format!(
        "{MUTED}{}{RESET}",
        upload_attempt_line(status, now, demo)
    ));
    if rows >= 9 {
        lines.push(format!(
            "{MUTED}{}{RESET}",
            compact_update_line(status, demo)
        ));
        lines.push(format!(
            "{CORAL}[Q] / [ESC]{RESET} {MUTED}back to shell{RESET}"
        ));
    } else {
        lines.push(format!(
            "{CORAL}{}{RESET} {MUTED}[Q] / [ESC] shell{RESET}",
            if demo {
                "Updates disabled"
            } else {
                "[U] update"
            }
        ));
    }
    if rows >= 17 {
        lines.insert(3, format!("{MUTED}{}{RESET}", source_line(status)));
    }

    let max_lines = rows.max(1);
    if lines.len() > max_lines {
        // Keep the state/heartbeat at the top and controls at the bottom; drop optional
        // middle detail when the terminal is too short.
        let footer = lines.pop().unwrap_or_default();
        lines.truncate(max_lines.saturating_sub(1));
        if max_lines > 0 {
            lines.push(footer);
        }
    }
    lines
        .iter()
        .map(|line| fit(line, width))
        .collect::<Vec<_>>()
        .join("\r\n")
        + "\r\n"
}

fn activity_tool_rows(lines: &[String]) -> usize {
    lines.len().saturating_sub(2)
}
