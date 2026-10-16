//! Read-only terminal dashboard. It never reads a credential or starts the collector.
use crate::config::{Paths, Result};
use chrono::{DateTime, Duration, Utc};
use serde_json::{json, Value};
use std::{
    collections::BTreeMap,
    io::{self, IsTerminal, Read, Write},
    time::SystemTime,
};
use tokrate_core::{read_private_file, History, TurnMetric};

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
fn spark(values: &[f64]) -> String {
    let bars = ['▁', '▂', '▃', '▄', '▅', '▆', '▇', '█'];
    let max = values.iter().copied().fold(1.0f64, f64::max);
    let min = values.iter().copied().fold(max, f64::min);
    values
        .iter()
        .rev()
        .take(18)
        .rev()
        .map(|v| bars[(((v - min) / (max - min).max(1.0) * 7.0).round() as usize).min(7)])
        .collect()
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

fn update_line(status: &Value, demo: bool) -> String {
    if demo {
        return "Updates are unavailable in the offline demo.".into();
    }
    let update = &status["update_check"];
    let checks = update["automaticChecks"].as_str().unwrap_or("unknown");
    let installed = update["installedVersion"]
        .as_str()
        .unwrap_or(tokrate_core::APP_VERSION);
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
    if cols < 68 || rows < 28 {
        let hero = &status["hero"];
        let speed = hero["speed"]
            .as_f64()
            .map(|v| format!("{v:.1} tok/s"))
            .unwrap_or("Waiting for data".into());
        return format!("{TEAL}T O K R A T E{RESET}  {}\r\n\r\n{WHITE}{speed}{RESET}\r\n{}\r\n{} / {}\r\n\r\n{} stored turns / {} queued\r\nSharing {} / sent {} since restart\r\nLast successful upload: {}\r\nLatest upload attempt: {}\r\n{}\r\n{} · [Q] / [ESC] back to shell\r\n",
            if demo { "DEMO / SYNTHETIC DATA" } else { "SERVER COMPANION" },
            fit(hero["label"].as_str().unwrap_or("Local monitoring"), cols.saturating_sub(2)),
            text(hero,"model"), text(hero,"provider"), count(status,"history_turns"), count(status,"pending_samples"),
            if status["sharing_active"].as_bool() == Some(true) { "ON" } else { "OFF" }, count(status,"uploaded_samples"),
            if demo { "Unavailable in offline demo".into() } else { last_successful_upload(status, Utc::now()) },
            latest_upload_attempt(status, Utc::now(), demo), update_line(status, demo),
            if demo { "Updates disabled in offline demo" } else { "[U] update" });
    }
    let width = cols.clamp(48, 110).saturating_sub(2);
    let inner = width - 4;
    let mut lines = vec![format!("{TEAL}╭{}╮{RESET}", "─".repeat(width - 2))];
    let mut line = |content: String| {
        lines.push(format!(
            "{TEAL}│{RESET} {}{RESET} {TEAL}│{RESET}",
            fit(&content, inner)
        ))
    };
    let mode = if demo {
        "DEMO / SYNTHETIC DATA"
    } else if status["monitoring"].as_bool() == Some(true) {
        "LOCAL COLLECTOR / LIVE"
    } else {
        "COLLECTOR STOPPED"
    };
    line(format!(
        "{WHITE}\x1b[1mT O K R A T E{RESET}  {MUTED}SERVER COMPANION{RESET}     {TEAL}{mode}"
    ));
    line(format!(
        "{MUTED}{}  /  {}  /  {} UTC",
        clean(&std::env::var("HOSTNAME").unwrap_or_else(|_| "debian-server".into())),
        std::env::consts::ARCH,
        Utc::now().format("%H:%M:%S")
    ));
    line(String::new());
    let hero = &status["hero"];
    let speed = hero["speed"]
        .as_f64()
        .filter(|v| v.is_finite() && *v >= 0.0);
    let label = hero["label"]
        .as_str()
        .unwrap_or("Waiting for a supported coding-tool observation");
    line(format!("{MUTED}{}", clean(label)));
    let big = big_number(&speed.map(|n| format!("{n:.1}")).unwrap_or("---".into()));
    let details = [
        format!("{WHITE}{}", text(hero, "model")),
        format!("{MUTED}{} / {}", text(hero, "tool"), text(hero, "provider")),
        format!("{TEAL}tok/s"),
        format!("{MUTED}Measured from local logs"),
        format!("{MUTED}No prompts. No code. No account."),
    ];
    for (index, digits) in big.iter().enumerate() {
        let expanded: String = digits.chars().flat_map(|c| [c, c]).collect();
        line(format!("{TEAL}{}   {}", fit(&expanded, 36), details[index]));
    }
    line(String::new());
    let recent: Vec<_> = records
        .iter()
        .filter(|m| m.completed_at >= Utc::now() - Duration::hours(24))
        .collect();
    let tokens: i64 = recent.iter().map(|m| m.output_tokens).sum();
    line(format!("{WHITE}{} {MUTED}turns / 24h     {WHITE}{:.1}k {MUTED}output tokens     {WHITE}{} {MUTED}stored / 7d",
        recent.len(), tokens as f64 / 1000.0, count(status,"history_turns")));
    line(format!("{MUTED}{}", "─".repeat(inner)));
    line(format!(
        "{WHITE}YOUR MODELS{RESET}   {MUTED}24h medians · RSP response / TURN whole-turn"
    ));
    let mut groups: BTreeMap<String, Vec<&TurnMetric>> = BTreeMap::new();
    for m in &recent {
        let key = json!([
            m.client,
            m.client_version,
            m.parser_version,
            m.metric_version,
            m.model,
            m.provider,
            m.provider_region,
            m.reasoning_effort,
            m.source_kind
        ])
        .to_string();
        groups.entry(key).or_default().push(m);
    }
    let mut groups: Vec<_> = groups.values().collect();
    groups.sort_by_key(|g| std::cmp::Reverse(g[0].completed_at));
    let max_models = if rows >= 34 { 4 } else { 2 };
    for group in groups.into_iter().take(max_models) {
        let newest = group[0];
        let mut rsp: Vec<f64> = group
            .iter()
            .filter_map(|m| m.plausible_response_timing().map(|(t, s, _)| t as f64 / s))
            .collect();
        let response = !rsp.is_empty();
        if !response {
            rsp = group
                .iter()
                .filter(|m| m.output_tokens >= 20)
                .map(|m| m.turn_throughput_tps)
                .collect();
        }
        let trend = spark(&rsp);
        let value = median(&mut rsp)
            .map(|v| format!("{v:>6.1}"))
            .unwrap_or("     —".into());
        let mut ttft: Vec<_> = group.iter().filter_map(|m| m.codex_ttft_seconds).collect();
        let first = median(&mut ttft)
            .map(|v| format!("{v:.2}s"))
            .unwrap_or("—".into());
        line(format!(
            "{TEAL}▸ {WHITE}{:<25} {CORAL}{value} {MUTED}{}  {TEAL}{trend}",
            clean(newest.model.as_deref().unwrap_or("unknown")),
            if response { "RSP " } else { "TURN" }
        ));
        line(format!(
            "{MUTED}  {} / {} / {} / {} · {} turns · first token {}",
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
        line(format!(
            "{MUTED}  Waiting for activity. Run Codex or another supported tool on this server."
        ));
    }
    line(format!("{MUTED}{}", "─".repeat(inner)));
    let sharing = if status["sharing_active"].as_bool() == Some(true) {
        "ON"
    } else {
        "OFF"
    };
    line(format!("{TEAL}● {WHITE}SHARING {sharing}{RESET}   {MUTED}queued {WHITE}{}{MUTED} samples + {WHITE}{}{MUTED} count entries  /  sent {WHITE}{} {MUTED}since restart",
        count(status,"pending_samples"), count(status,"pending_request_counts"), count(status,"uploaded_samples")));
    line(format!(
        "{MUTED}  Last successful upload: {}",
        if demo {
            "Unavailable in offline demo".into()
        } else {
            last_successful_upload(status, Utc::now())
        }
    ));
    line(format!(
        "{MUTED}  Latest upload attempt: {}",
        latest_upload_attempt(status, Utc::now(), demo)
    ));
    line(format!(
        "{MUTED}  Sources: {}{}",
        text(status, "source_summary"),
        if status["source_error"].as_bool() == Some(true) {
            " / READ ERROR"
        } else {
            ""
        }
    ));
    line(format!("{MUTED}{}", update_line(status, demo)));
    line(String::new());
    line(format!(
        "{} {CORAL}[Q] / [ESC]{RESET} {MUTED}back to shell · collector keeps running     {TEAL}tokrate.dev",
        if demo {
            format!("{MUTED}Updates disabled in offline demo")
        } else {
            format!("{CORAL}[U]{RESET} {MUTED}update")
        }
    ));
    lines.push(format!("{TEAL}╰{}╯{RESET}", "─".repeat(width - 2)));
    lines.join("\r\n") + "\r\n"
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
                Utc::now() - Duration::minutes(i * 3),
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
        json!({"monitoring":true, "history_turns":1248, "sharing_active":true, "pending_samples":6,
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
                let stale = status["updated_at"]
                    .as_str()
                    .and_then(|s| chrono::DateTime::parse_from_rfc3339(s).ok())
                    .is_none_or(|at| Utc::now().signed_duration_since(at).num_seconds() > 10);
                if stale {
                    status["monitoring"] = false.into();
                    status["sharing_active"] = false.into();
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
                status["update_check"] = crate::updater::status_value(tokrate_core::APP_VERSION);
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
        assert_eq!(spark(&[2.0; 50]).chars().count(), 18);
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
}
