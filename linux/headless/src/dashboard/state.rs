use chrono::{DateTime, Duration, Utc};
use serde_json::Value;

const STALE_AFTER_SECONDS: i64 = 10;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum Heartbeat {
    Fresh { age_seconds: u64 },
    Stale { age_seconds: u64 },
    ClockAhead { seconds: u64 },
    Unknown,
}

pub(crate) fn parse_time(value: &Value) -> Option<DateTime<Utc>> {
    value
        .as_str()
        .and_then(|text| DateTime::parse_from_rfc3339(text).ok())
        .map(|at| at.with_timezone(&Utc))
}

pub(crate) fn heartbeat(status: &Value, now: DateTime<Utc>) -> Heartbeat {
    let Some(updated_at) = parse_time(&status["updated_at"]) else {
        return Heartbeat::Unknown;
    };
    if updated_at > now {
        let ahead = updated_at.signed_duration_since(now);
        Heartbeat::ClockAhead {
            seconds: ceiling_seconds(ahead),
        }
    } else {
        let age = now.signed_duration_since(updated_at);
        if age > Duration::seconds(STALE_AFTER_SECONDS) {
            Heartbeat::Stale {
                age_seconds: ceiling_seconds(age),
            }
        } else {
            Heartbeat::Fresh {
                age_seconds: age.num_seconds().max(0) as u64,
            }
        }
    }
}

fn ceiling_seconds(duration: Duration) -> u64 {
    (duration.num_milliseconds().max(0) as u64).saturating_add(999) / 1_000
}

pub(crate) fn uptime_seconds(status: &Value, heartbeat: Heartbeat) -> Option<u64> {
    let captured = status["uptime_seconds"].as_u64()?;
    if status["monitoring"].as_bool() == Some(true) {
        if let Heartbeat::Fresh { age_seconds } = heartbeat {
            return Some(captured.saturating_add(age_seconds));
        }
    }
    Some(captured)
}

pub(crate) fn format_duration(seconds: u64) -> String {
    let days = seconds / 86_400;
    let hours = (seconds % 86_400) / 3_600;
    let minutes = (seconds % 3_600) / 60;
    if days > 0 {
        format!("{days}d {hours}h {minutes}m")
    } else if hours > 0 {
        format!("{hours}h {minutes}m")
    } else if minutes > 0 {
        format!("{minutes}m")
    } else {
        format!("{seconds}s")
    }
}

pub(crate) fn schedule_line(
    status: &Value,
    heartbeat: Heartbeat,
    now: DateTime<Utc>,
    demo: bool,
) -> String {
    match heartbeat {
        Heartbeat::Stale { age_seconds } => {
            return format!("Schedule unavailable · heartbeat stale ({age_seconds}s)");
        }
        Heartbeat::ClockAhead { seconds } => {
            return format!("Schedule unavailable · clock is ahead ({seconds}s)");
        }
        Heartbeat::Unknown => return "Upload schedule unavailable · heartbeat unknown".into(),
        Heartbeat::Fresh { .. } => {}
    }

    if status["monitoring"].as_bool() != Some(true) {
        return "Collector stopped · no upload countdown".into();
    }
    if status["sharing_active"].as_bool() != Some(true) {
        return "Sharing off · no upload countdown".into();
    }

    let schedule = &status["upload_schedule"];
    match schedule["state"].as_str().unwrap_or("unknown") {
        "off" => "Sharing off · no upload countdown".into(),
        "stopped" => "Collector stopped · no upload countdown".into(),
        "uploading" => "Upload in progress".into(),
        "idle" => "No uploads queued · schedule idle".into(),
        "scheduled" => {
            let Some(at) = parse_time(&schedule["next_attempt_at"]) else {
                return "Estimated next attempt unavailable".into();
            };
            if at <= now {
                return "Upload attempt due · waiting for the collector's next attempt".into();
            }
            let countdown = format_duration(ceiling_seconds(at.signed_duration_since(now)));
            let label = if demo {
                "Demo estimate"
            } else {
                "Estimated next attempt"
            };
            format!("{label} in {countdown} · {} UTC", at.format("%H:%M:%S"))
        }
        _ => "Upload schedule unavailable".into(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::TimeZone;
    use serde_json::json;

    fn now() -> DateTime<Utc> {
        Utc.with_ymd_and_hms(2026, 10, 16, 12, 0, 0).unwrap()
    }

    fn live_status(updated_at: &str, uptime_seconds: Value) -> Value {
        json!({
            "updated_at": updated_at,
            "uptime_seconds": uptime_seconds,
            "monitoring": true,
            "sharing_active": true
        })
    }

    #[test]
    fn heartbeat_distinguishes_fresh_stale_future_and_missing_values() {
        assert_eq!(
            heartbeat(&live_status("2026-10-16T11:59:50Z", json!(10)), now()),
            Heartbeat::Fresh { age_seconds: 10 }
        );
        assert_eq!(
            heartbeat(&live_status("2026-10-16T11:59:49.999Z", json!(10)), now()),
            Heartbeat::Stale { age_seconds: 11 }
        );
        assert_eq!(
            heartbeat(&live_status("2026-10-16T11:59:49Z", json!(10)), now()),
            Heartbeat::Stale { age_seconds: 11 }
        );
        assert_eq!(
            heartbeat(&live_status("2026-10-16T12:00:00.500Z", json!(10)), now()),
            Heartbeat::ClockAhead { seconds: 1 }
        );
        assert_eq!(heartbeat(&json!({}), now()), Heartbeat::Unknown);
    }

    #[test]
    fn uptime_advances_only_for_fresh_running_collector() {
        let status = live_status("2026-10-16T11:59:56Z", json!(120));
        assert_eq!(
            uptime_seconds(&status, heartbeat(&status, now())),
            Some(124)
        );
        let stale = live_status("2026-10-16T11:59:40Z", json!(120));
        assert_eq!(uptime_seconds(&stale, heartbeat(&stale, now())), Some(120));
        let stopped = json!({"monitoring":false, "uptime_seconds":120});
        assert_eq!(
            uptime_seconds(&stopped, Heartbeat::Fresh { age_seconds: 4 }),
            Some(120)
        );
        assert_eq!(uptime_seconds(&json!({}), Heartbeat::Unknown), None);
    }

    #[test]
    fn schedule_is_truthful_for_missing_due_and_stale_status() {
        let fresh = Heartbeat::Fresh { age_seconds: 0 };
        let scheduled = json!({
            "monitoring":true,
            "sharing_active":true,
            "upload_schedule":{"state":"scheduled", "next_attempt_at":"2026-10-16T12:00:31Z"}
        });
        assert!(schedule_line(&scheduled, fresh, now(), false)
            .contains("Estimated next attempt in 31s"));
        let shortly_scheduled = json!({
            "monitoring":true,
            "sharing_active":true,
            "upload_schedule":{"state":"scheduled", "next_attempt_at":"2026-10-16T12:00:00.500Z"}
        });
        assert!(schedule_line(&shortly_scheduled, fresh, now(), false).contains("in 1s"));
        let due = json!({
            "monitoring":true,
            "sharing_active":true,
            "upload_schedule":{"state":"scheduled", "next_attempt_at":"2026-10-16T11:59:59Z"}
        });
        let due_line = schedule_line(&due, fresh, now(), false);
        assert!(due_line.contains("due"));
        assert!(due_line.contains("waiting"));
        assert!(!due_line.contains("in 0s"));
        assert!(schedule_line(
            &json!({"monitoring":true,"sharing_active":true}),
            fresh,
            now(),
            false
        )
        .contains("unavailable"));
        assert!(schedule_line(
            &scheduled,
            Heartbeat::Stale { age_seconds: 18 },
            now(),
            false
        )
        .contains("heartbeat stale"));
        assert!(schedule_line(
            &scheduled,
            Heartbeat::ClockAhead { seconds: 1 },
            now(),
            false
        )
        .contains("clock is ahead"));
    }
}
