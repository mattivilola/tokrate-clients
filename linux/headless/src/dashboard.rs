//! Read-only terminal dashboard. It never reads a credential or starts the collector.
mod activity;
mod render;
mod state;

use crate::config::{Paths, Result};
use chrono::{DateTime, Duration, Utc};
use serde_json::{json, Value};
use std::{
    collections::BTreeMap,
    io::{self, IsTerminal, Read, Write},
    time::SystemTime,
};
use tokrate_core::{read_private_file, History, TurnMetric};

use activity::{spark as activity_spark, tool_activity};
use state::{format_duration, heartbeat, parse_time, schedule_line, uptime_seconds, Heartbeat};

const RESET: &str = "\x1b[0m\x1b[48;5;234m";
const TEAL: &str = "\x1b[38;5;80m";
const CORAL: &str = "\x1b[38;5;210m";
const WHITE: &str = "\x1b[38;5;255m";
const MUTED: &str = "\x1b[38;5;245m";

fn clean(text: &str) -> String {
    // Names in source logs are untrusted. Never emit their control/OSC/ANSI sequences.
    text.chars()
        .filter(|c| c.is_ascii_graphic() || *c == ' ')
        .take(120)
        .collect()
}
fn text(value: &Value, key: &str) -> String {
    clean(value[key].as_str().unwrap_or("—"))
}
fn count(value: &Value, key: &str) -> u64 {
    value[key].as_u64().unwrap_or(0)
}
fn relative_age(at: DateTime<Utc>, now: DateTime<Utc>) -> String {
    let seconds = now.signed_duration_since(at).num_seconds();
    if seconds < 0 {
        return "clock is ahead".into();
    }
    match seconds {
        0..=5 => "just now".into(),
        6..=59 => format!("{seconds}s ago"),
        60..=3_599 => format!("{}m ago", seconds / 60),
        3_600..=86_399 => format!("{}h {}m ago", seconds / 3_600, (seconds % 3_600) / 60),
        _ => format!("{}d {}h ago", seconds / 86_400, (seconds % 86_400) / 3_600),
    }
}
fn upload_time(value: &Value, key: &str, now: DateTime<Utc>) -> Option<String> {
    let at = value[key]
        .as_str()
        .and_then(|text| DateTime::parse_from_rfc3339(text).ok())?
        .with_timezone(&Utc);
    Some(format!(
        "{} UTC · {}",
        at.format("%Y-%m-%d %H:%M:%S"),
        relative_age(at, now)
    ))
}
fn last_successful_upload(status: &Value, now: DateTime<Utc>) -> String {
    upload_time(status, "last_upload_successful_at", now)
        .unwrap_or_else(|| "No successful upload recorded yet".into())
}
fn latest_upload_attempt(status: &Value, now: DateTime<Utc>, demo: bool) -> String {
    if demo {
        return "Unavailable in offline demo".into();
    }
    let Some(at) = upload_time(status, "last_upload_at", now) else {
        return "No upload attempts recorded".into();
    };
    let result = status["last_upload_attempt_result"]
        .as_str()
        .or_else(|| status["last_upload_result"].as_str())
        .unwrap_or("outcome unavailable");
    format!("{at} · {}", clean(result))
}
fn median(values: &mut [f64]) -> Option<f64> {
    if values.is_empty() {
        return None;
    }
    values.sort_by(f64::total_cmp);
    let i = values.len() / 2;
    Some(if values.len().is_multiple_of(2) {
        (values[i - 1] + values[i]) / 2.0
    } else {
        values[i]
    })
}
fn fit(text: &str, width: usize) -> String {
    let mut result = String::new();
    let mut escape = false;
    let mut visible = 0;
    for c in text.chars() {
        if c == '\x1b' {
            escape = true;
        }
        if escape {
            result.push(c);
            if c == 'm' {
                escape = false;
            }
        } else {
            if visible == width {
                break;
            }
            result.push(c);
            visible += 1;
        }
    }
    result.push_str(&" ".repeat(width.saturating_sub(visible)));
    result
}

fn value_spark(values: &[f64]) -> String {
    let bars = ['▁', '▂', '▃', '▄', '▅', '▆', '▇', '█'];
    let max = values.iter().copied().fold(1.0f64, f64::max);
    let min = values.iter().copied().fold(max, f64::min);
    values
        .iter()
        .take(18)
        .map(|value| bars[((value - min) / (max - min).max(1.0) * 7.0).round() as usize])
        .collect()
}

fn update_line(status: &Value, demo: bool) -> String {
    if demo {
        return "Updates are unavailable in the offline demo.".into();
    }
    let update = &status["update_check"];
    let checks = update["automaticChecks"].as_str().unwrap_or("unknown");
    let installed = update["installedVersion"]
        .as_str()
        .unwrap_or(crate::APP_VERSION);
    match update["state"].as_str().unwrap_or("never-checked") {
        "available" => format!(
            "Update available: {} → {} · automatic checks {} · press U to update",
            installed,
            update["availableVersion"].as_str().unwrap_or("unknown"),
            checks
        ),
        "up-to-date" => format!("Already up to date: {installed} · automatic checks {checks}"),
        "stale" => format!("Update check is stale · automatic checks {checks} · press U to refresh and update"),
        "error" => format!("Could not check for updates · automatic checks {checks}"),
        _ => format!("Update availability has not been checked · automatic checks {checks} · press U to check"),
    }
}

fn big_number(value: &str) -> Vec<String> {
    let digits = [
        ["███", "█ █", "█ █", "█ █", "███"],
        [" █ ", "██ ", " █ ", " █ ", "███"],
        ["███", "  █", "███", "█  ", "███"],
        ["███", "  █", "███", "  █", "███"],
        ["█ █", "█ █", "███", "  █", "  █"],
        ["███", "█  ", "███", "  █", "███"],
        ["███", "█  ", "███", "█ █", "███"],
        ["███", "  █", "  █", "  █", "  █"],
        ["███", "█ █", "███", "█ █", "███"],
        ["███", "█ █", "███", "  █", "███"],
    ];
    (0..5)
        .map(|row| {
            value
                .chars()
                .take(7)
                .map(|c| {
                    c.to_digit(10)
                        .map(|n| digits[n as usize][row])
                        .unwrap_or(if row == 4 { " ▪ " } else { "   " })
                })
                .collect::<Vec<_>>()
                .join(" ")
        })
        .collect()
}

pub(crate) fn render(
    status: &Value,
    records: &[TurnMetric],
    cols: usize,
    rows: usize,
    demo: bool,
) -> String {
    render::render_at(status, records, cols, rows, demo, Utc::now())
}

struct Terminal {
    original: libc::termios,
}
impl Terminal {
    fn enter() -> Result<Self> {
        if !io::stdin().is_terminal() || !io::stdout().is_terminal() {
            return Err("status-monitor needs an interactive terminal; use status for JSON or --demo --once for a preview".into());
        }
        let mut original = std::mem::MaybeUninit::uninit();
        if unsafe { libc::tcgetattr(libc::STDIN_FILENO, original.as_mut_ptr()) } != 0 {
            return Err(io::Error::last_os_error().into());
        }
        let original = unsafe { original.assume_init() };
        let mut raw = original;
        unsafe {
            libc::cfmakeraw(&mut raw);
        }
        if unsafe { libc::tcsetattr(libc::STDIN_FILENO, libc::TCSANOW, &raw) } != 0 {
            return Err(io::Error::last_os_error().into());
        }
        let guard = Self { original };
        print!("\x1b[?1049h\x1b[?25l");
        io::stdout().flush()?;
        Ok(guard)
    }
}
impl Drop for Terminal {
    fn drop(&mut self) {
        unsafe {
            libc::tcsetattr(libc::STDIN_FILENO, libc::TCSANOW, &self.original);
        }
        print!("\x1b[0m\x1b[?25h\x1b[?1049l");
        let _ = io::stdout().flush();
    }
}

fn size() -> (usize, usize) {
    let mut size = std::mem::MaybeUninit::<libc::winsize>::zeroed();
    if unsafe { libc::ioctl(libc::STDOUT_FILENO, libc::TIOCGWINSZ, size.as_mut_ptr()) } == 0 {
        let size = unsafe { size.assume_init() };
        if size.ws_col > 0 && size.ws_row > 0 {
            return (size.ws_col as usize, size.ws_row as usize);
        }
    }
    (110, 36)
}

fn demo() -> (Value, Vec<TurnMetric>) {
    let now = Utc::now();
    let mut records = Vec::new();
    for (model, provider, tool, speed) in [
        ("gpt-6.1-sol", "openai", "codex", 84.7),
        ("claude-opus-5-5", "anthropic", "claude-code", 62.3),
        ("grok-4.7-build", "xai", "grok-build", 106.2),
    ] {
        for i in 0..18 {
            let output = (speed * (0.78 + ((i * 7) % 11) as f64 * 0.04) * 10.0) as i64;
            let mut m = TurnMetric::new(
                format!("demo-{model}-{i}"),
                now - Duration::minutes(i * 3),
                Some(model.into()),
                output,
                if tool == "grok-build" { 10.0 } else { 24.0 },
                (tool == "codex").then_some(0.42),
                output as f64 / if tool == "grok-build" { 10.0 } else { 24.0 },
                None,
                None,
                None,
                Some("primary".into()),
                Some(provider.into()),
                Some("high".into()),
            );
            m.client = tool.into();
            if tool != "grok-build" {
                m.response_output_tokens = Some(output);
                m.response_duration_seconds = Some(10.0);
                m.response_count = Some(1);
            }
            records.push(m);
        }
    }
    records.sort_by_key(|m| std::cmp::Reverse(m.completed_at));
    (
        json!({"monitoring":true, "started_at":(now - Duration::seconds(31562)).to_rfc3339(),
            "updated_at":(now - Duration::seconds(2)).to_rfc3339(), "uptime_seconds":31560,
            "upload_schedule":{"state":"scheduled", "next_attempt_at":(now + Duration::minutes(3)).to_rfc3339()},
            "history_turns":1248, "sharing_active":true, "pending_samples":6,
            "pending_request_counts":2, "uploaded_samples":482,
            "source_summary":"Codex + Claude Code + Grok Build",
            "hero":{"speed":84.7, "model":"gpt-6.1-sol", "provider":"openai", "tool":"codex", "label":"Response speed / last 5 responses"}}),
        records,
    )
}

pub async fn monitor(paths: &Paths, preview: bool, once: bool) -> Result<bool> {
    let _terminal = if once { None } else { Some(Terminal::enter()?) };
    let mut interrupt = tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate())?;
    let mut tick = tokio::time::interval(std::time::Duration::from_millis(100));
    let mut last_draw = std::time::Instant::now() - std::time::Duration::from_secs(1);
    let mut cache: Option<SystemTime> = None;
    let mut history = History::default();
    loop {
        if last_draw.elapsed().as_secs() >= 1 {
            let (status, records) = if preview {
                demo()
            } else {
                let mut status: Value = read_private_file(paths.data.join("status.json"), 1_048_576).ok()
                    .and_then(|b| serde_json::from_slice(&b).ok()).filter(Value::is_object)
                    .unwrap_or_else(|| json!({"last_upload_result":"No collector status yet. Run setup/start the systemd service."}));
                let modified = std::fs::metadata(paths.data.join("history.json"))
                    .and_then(|m| m.modified())
                    .ok();
                if modified != cache {
                    if let Ok(loaded) = History::load(paths.data.join("history.json"), Utc::now()) {
                        history = loaded;
                    }
                    cache = modified;
                }
                status["source_summary"] = paths
                    .load()
                    .map(|s| {
                        s.roots()
                            .into_iter()
                            .filter(|(_, p)| p.exists())
                            .map(|(name, _)| name.to_owned())
                            .collect::<Vec<_>>()
                            .join(" + ")
                    })
                    .unwrap_or_else(|_| "Setup required".into())
                    .into();
                status["update_check"] = crate::updater::status_value(crate::APP_VERSION);
                (status, history.records().to_vec())
            };
            let (cols, rows) = size();
            if !once {
                print!("{RESET}\x1b[2J\x1b[H");
            }
            print!("{}", render(&status, &records, cols, rows, preview));
            if once {
                print!("\x1b[0m");
            }
            io::stdout().flush()?;
            if once {
                return Ok(false);
            }
            last_draw = std::time::Instant::now();
        }
        tokio::select! { _ = interrupt.recv() => return Ok(false), _ = tick.tick() => {} }
        let mut fd = libc::pollfd {
            fd: libc::STDIN_FILENO,
            events: libc::POLLIN,
            revents: 0,
        };
        if unsafe { libc::poll(&mut fd, 1, 0) } > 0 {
            if fd.revents & (libc::POLLHUP | libc::POLLERR) != 0 {
                return Ok(false);
            }
            if fd.revents & libc::POLLIN != 0 {
                let mut key = [0];
                if io::stdin().read(&mut key)? == 0 || matches!(key[0], b'q' | b'Q' | 27 | 3) {
                    return Ok(false);
                }
                if !preview && matches!(key[0], b'u' | b'U') {
                    return Ok(true);
                }
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::TimeZone;

    #[test]
    fn terminal_output_sanitizes_source_control_sequences_and_labels_demo() {
        let (mut status, records) = demo();
        status["hero"]["model"] = "hostile\x1b]52;c;clipboard-secret\x07".into();
        let rendered = render(&status, &records, 110, 36, true);
        assert!(rendered.contains("DEMO / SYNTHETIC DATA"));
        assert!(rendered.contains("Updates disabled in offline demo"));
        assert!(!rendered.contains("[U] update"));
        assert!(!rendered.contains("\x1b]52"));
        assert!(rendered.contains("RSP response / TURN whole-turn"));
        assert!(rendered.contains("[Q] / [ESC]"));
    }
    #[test]
    fn unavailable_medians_are_not_zero_and_spark_is_bounded() {
        assert_eq!(median(&mut []), None);
        assert_eq!(median(&mut [2.0, 4.0]), Some(3.0));
        assert_eq!(
            activity_spark(&[2; activity::BIN_COUNT]).chars().count(),
            activity::BIN_COUNT
        );
    }

    #[test]
    fn upload_status_uses_utc_relative_age_and_explicit_empty_state() {
        let now = Utc.with_ymd_and_hms(2026, 10, 16, 12, 5, 32).unwrap();
        let status = json!({
            "last_upload_successful_at":"2026-10-16T12:00:00Z",
            "last_upload_at":"2026-10-16T12:04:30Z",
            "last_upload_failed_at":"2026-10-16T11:45:00Z",
            "last_upload_attempt_result":"http-503; retry pending"
        });
        assert_eq!(
            last_successful_upload(&status, now),
            "2026-10-16 12:00:00 UTC · 5m ago"
        );
        assert_eq!(
            latest_upload_attempt(&status, now, false),
            "2026-10-16 12:04:30 UTC · 1m ago · http-503; retry pending"
        );
        assert_eq!(
            last_successful_upload(&json!({}), now),
            "No successful upload recorded yet"
        );
        assert_eq!(
            latest_upload_attempt(&json!({}), now, false),
            "No upload attempts recorded"
        );
        assert_eq!(
            latest_upload_attempt(&status, now, true),
            "Unavailable in offline demo"
        );
    }

    #[test]
    fn dashboard_labels_report_upload_time_and_restart_scoped_counter() {
        let status = json!({
            "sharing_active":false,
            "uploaded_samples":12,
            "last_upload_successful_at":"2026-10-16T12:00:00Z",
            "last_upload_at":"2026-10-16T12:04:30Z",
            "last_upload_attempt_result":"http-503; retry pending",
            "update_check":{"automaticChecks":"off","state":"never-checked"}
        });
        let rendered = render(&status, &[], 110, 36, false);
        assert!(rendered.contains("since restart"));
        assert!(rendered.contains("12"));
        assert!(rendered.contains("Last successful upload: 2026-10-16 12:00:00 UTC"));
        assert!(rendered.contains("Latest upload attempt: 2026-10-16 12:04:30 UTC"));
        let empty = render(&json!({"sharing_active":false}), &[], 110, 36, false);
        assert!(empty.contains("No successful upload recorded yet"));
    }

    fn strip_ansi(text: &str) -> String {
        let mut output = String::new();
        let mut escape = false;
        for character in text.chars() {
            if character == '\x1b' {
                escape = true;
                continue;
            }
            if escape {
                if character == 'm' {
                    escape = false;
                }
                continue;
            }
            output.push(character);
        }
        output
    }

    #[test]
    fn compact_and_full_layouts_stay_inside_terminal_rows_and_columns() {
        let (status, records) = demo();
        for (cols, rows) in [(110, 36), (80, 24), (60, 16), (42, 10), (28, 8)] {
            let rendered = strip_ansi(&render::render_at(
                &status,
                &records,
                cols,
                rows,
                true,
                Utc::now(),
            ));
            let visible: Vec<_> = rendered.lines().collect();
            assert!(
                visible.len() <= rows,
                "{cols}×{rows}: {} rows",
                visible.len()
            );
            for (index, line) in visible.iter().enumerate() {
                assert!(
                    line.chars().count() <= cols,
                    "{cols}×{rows}, line {index}: {} columns: {line:?}",
                    line.chars().count()
                );
            }
            assert!(rendered.contains("T O K R A T E"));
            assert!(rendered.contains("Updated") || rows < 3);
            assert!(rendered.contains("[Q]"));
        }
    }

    #[test]
    fn stale_and_future_heartbeats_hide_the_schedule_countdown() {
        let now = Utc.with_ymd_and_hms(2026, 10, 16, 12, 0, 0).unwrap();
        for updated_at in ["2026-10-16T11:59:40Z", "2026-10-16T12:00:01Z"] {
            let status = json!({
                "monitoring":true,
                "sharing_active":true,
                "updated_at":updated_at,
                "uptime_seconds":60,
                "upload_schedule":{"state":"scheduled", "next_attempt_at":"2026-10-16T12:05:00Z"}
            });
            let rendered = render::render_at(&status, &[], 80, 24, false, now);
            assert!(rendered.contains("heartbeat stale") || rendered.contains("clock is ahead"));
            assert!(!rendered.contains("Estimated next attempt in"));
            assert!(rendered.contains("Last successful upload:"));
            assert!(rendered.contains("Latest upload attempt:"));
        }
    }

    #[test]
    fn activity_distinguishes_empty_history_from_zero_and_unavailable_collector() {
        let now = Utc.with_ymd_and_hms(2026, 10, 16, 12, 0, 0).unwrap();
        let fresh = json!({
            "monitoring":true,
            "updated_at":now.to_rfc3339(),
            "history_turns":0
        });
        assert!(render::activity_lines(&fresh, &[], now)[2].contains("No local turn history yet"));

        let measured_zero = json!({
            "monitoring":true,
            "updated_at":now.to_rfc3339(),
            "history_turns":10
        });
        assert!(render::activity_lines(&measured_zero, &[], now)[2]
            .contains("No completed turns in these recent bins"));

        let stopped = json!({"monitoring":false, "history_turns":10});
        assert!(render::activity_lines(&stopped, &[], now)[2].contains("Collector unavailable"));
        let unreadable = json!({"monitoring":false, "history_error":true});
        assert!(
            render::activity_lines(&unreadable, &[], now)[2].contains("unavailable (read error)")
        );
    }
}
