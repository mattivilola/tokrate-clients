use crate::{SourceChange, SourceCheckpoints, SourceMonitor, TurnMetric, CODEX_CLIENT};
use chrono::{DateTime, Duration, SecondsFormat, Utc};
use serde_json::{json, Value};
use std::collections::HashSet;
use std::fs::{self, FileTimes, OpenOptions};
use std::io::Write;
use std::path::{Path, PathBuf};
use std::time::{Duration as StdDuration, SystemTime};
use uuid::Uuid;

struct TestDir(PathBuf);

impl TestDir {
    fn new() -> Self {
        let path = std::env::temp_dir().join(format!("tokrate-codex-profiles-{}", Uuid::new_v4()));
        fs::create_dir_all(&path).unwrap();
        Self(path)
    }

    fn path(&self) -> &Path {
        &self.0
    }
}

impl Drop for TestDir {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}

fn source_monitor(base: &Path, codex_root: PathBuf) -> SourceMonitor {
    SourceMonitor::new(
        codex_root,
        base.join("claude"),
        base.join("grok"),
        base.join("antigravity"),
        base.join("opencode"),
        base.join("kimi"),
        base.join("kimi-desktop"),
    )
}

fn timestamp(at: DateTime<Utc>) -> String {
    at.to_rfc3339_opts(SecondsFormat::Millis, true)
}

fn line(kind: &str, payload: Value, at: DateTime<Utc>) -> Vec<u8> {
    serde_json::to_vec(&json!({
        "timestamp": timestamp(at),
        "type": kind,
        "payload": payload,
    }))
    .unwrap()
}

fn turn_lines(
    session: &str,
    turn: &str,
    completed_at: DateTime<Utc>,
    include_session_meta: bool,
) -> Vec<Vec<u8>> {
    let started_at = completed_at - Duration::seconds(10);
    let mut lines = Vec::new();
    if include_session_meta {
        lines.push(line(
            "session_meta",
            json!({
                "id": session,
                "source": "cli",
                "model_provider": "openai",
                "cli_version": "0.159.2"
            }),
            started_at,
        ));
    }
    lines.extend([
        line(
            "event_msg",
            json!({"type":"task_started", "turn_id":turn, "started_at":timestamp(started_at)}),
            started_at,
        ),
        line(
            "turn_context",
            json!({"turn_id":turn, "model":"gpt-test", "effort":"high"}),
            started_at,
        ),
        line(
            "response_item",
            json!({"type":"message", "role":"user"}),
            started_at,
        ),
        line("response_item", json!({"type":"reasoning"}), started_at),
        line(
            "token_usage_record",
            json!({
                "turn_id": turn,
                "response_id": format!("response-{turn}"),
                "usage": {"output_tokens": 400},
                "turn_token_usage": {"output_tokens": 400}
            }),
            completed_at,
        ),
        line(
            "event_msg",
            json!({
                "type":"task_complete",
                "turn_id":turn,
                "started_at":timestamp(started_at),
                "completed_at":timestamp(completed_at),
                "duration_ms":10_000
            }),
            completed_at,
        ),
    ]);
    lines
}

fn write_turn(
    root: &Path,
    session: &str,
    turn: &str,
    completed_at: DateTime<Utc>,
    modified_at: Option<SystemTime>,
) -> PathBuf {
    fs::create_dir_all(root).unwrap();
    let path = root.join("rollout.jsonl");
    let mut contents = Vec::new();
    for line in turn_lines(session, turn, completed_at, true) {
        contents.extend_from_slice(&line);
        contents.push(b'\n');
    }
    fs::write(&path, contents).unwrap();
    if let Some(modified_at) = modified_at {
        OpenOptions::new()
            .write(true)
            .open(&path)
            .unwrap()
            .set_times(FileTimes::new().set_modified(modified_at))
            .unwrap();
    }
    path
}

fn append_turn(path: &Path, session: &str, turn: &str, completed_at: DateTime<Utc>) {
    let mut file = OpenOptions::new().append(true).open(path).unwrap();
    for line in turn_lines(session, turn, completed_at, false) {
        file.write_all(&line).unwrap();
        file.write_all(b"\n").unwrap();
    }
}

fn poll_until_idle(monitor: &mut SourceMonitor, now: DateTime<Utc>) -> Vec<TurnMetric> {
    let mut found = Vec::new();
    for _ in 0..100 {
        found.extend(monitor.poll(now).unwrap());
        if monitor.next_poll_deadline(now).is_none() {
            return found;
        }
    }
    panic!("source profiles did not settle");
}

#[test]
fn additional_roots_are_bounded_and_reject_duplicates_or_overlaps() {
    let temp = TestDir::new();
    let default = temp.path().join("default");
    let base = || source_monitor(temp.path(), default.clone());

    assert!(base()
        .with_additional_codex_roots(vec![default.clone()])
        .is_err());
    assert!(base()
        .with_additional_codex_roots(vec![default.join("nested")])
        .is_err());
    assert!(base()
        .with_additional_codex_roots(vec![
            temp.path().join("one"),
            temp.path().join("two"),
            temp.path().join("three"),
            temp.path().join("four"),
        ])
        .is_err());
    assert!(base()
        .with_additional_codex_roots(vec![temp.path().join("a/../default/child")])
        .is_err());

    let four_profiles = base()
        .with_additional_codex_roots(vec![
            temp.path().join("one"),
            temp.path().join("two"),
            temp.path().join("three"),
        ])
        .unwrap();
    assert_eq!(four_profiles.watch_folders("codex").len(), 4);
    assert!(four_profiles
        .with_additional_codex_roots(vec![temp.path().join("four")])
        .is_err());
}

#[test]
fn default_and_additional_profiles_collect_and_have_unique_watcher_routes() {
    let temp = TestDir::new();
    let default = temp.path().join("default");
    let extra = temp.path().join("extra");
    let completed = Utc::now() - Duration::minutes(3);
    write_turn(&default, "default-session", "turn-1", completed, None);
    let extra_file = write_turn(&extra, "extra-session", "turn-1", completed, None);
    let now = Utc::now() + Duration::minutes(1);

    let mut monitor = source_monitor(temp.path(), default.clone())
        .with_additional_codex_roots(vec![extra.clone()])
        .unwrap();
    let found = poll_until_idle(&mut monitor, now);
    let ids: HashSet<_> = found.iter().map(|turn| turn.id.clone()).collect();
    assert_eq!(ids.len(), 2);
    assert!(found.iter().all(|turn| turn.client == CODEX_CLIENT));

    let folders = monitor.watch_folders("codex");
    assert_eq!(
        folders.iter().map(|folder| folder.name).collect::<Vec<_>>(),
        ["codex", "codex-extra-1"]
    );
    assert_eq!(folders[0].path, default);
    assert_eq!(folders[1].path, extra);
    assert!(folders.iter().all(|folder| folder.recursive));
    assert_eq!(monitor.root_exists("codex-extra-1"), Some(true));
    assert_eq!(monitor.root("codex-extra-1"), Some(&extra));
    assert_eq!(monitor.root_exists("codex-extra-2"), None);

    let appended_at = completed + Duration::minutes(1);
    append_turn(&extra_file, "extra-session", "turn-2", appended_at);
    let change = SourceChange {
        paths: [extra_file].into_iter().collect(),
        must_rescan: false,
    };
    assert!(monitor.note_changes(&change));
    assert_eq!(monitor.next_poll_deadline(now), Some(now));
    let appended = poll_until_idle(&mut monitor, now);
    assert!(appended
        .iter()
        .any(|turn| { turn.completed_at.timestamp_millis() == appended_at.timestamp_millis() }));
    assert!(appended.iter().all(|turn| turn.client == CODEX_CLIENT));
    assert!(!monitor.note_changes(&SourceChange {
        paths: [default.join("unrelated.txt")].into_iter().collect(),
        must_rescan: false,
    }));
}

#[test]
fn codex_profiles_deduplicate_identical_metric_ids() {
    let temp = TestDir::new();
    let default = temp.path().join("default");
    let extra = temp.path().join("extra");
    let completed = Utc::now() - Duration::minutes(3);
    write_turn(&default, "same-session", "same-turn", completed, None);
    write_turn(&extra, "same-session", "same-turn", completed, None);
    let mut monitor = source_monitor(temp.path(), default)
        .with_additional_codex_roots(vec![extra])
        .unwrap();

    let found = poll_until_idle(&mut monitor, Utc::now() + Duration::minutes(1));
    let ids: HashSet<_> = found.iter().map(|turn| turn.id.clone()).collect();
    assert_eq!(ids.len(), 1);
}

#[test]
fn profiles_share_codex_budget_fairly_and_remain_within_global_limit() {
    let temp = TestDir::new();
    let completed = Utc::now() - Duration::minutes(3);
    let roots: Vec<_> = (0..4)
        .map(|index| temp.path().join(format!("profile-{index}")))
        .collect();
    for (index, root) in roots.iter().enumerate() {
        let path = write_turn(
            root,
            &format!("session-{index}"),
            &format!("turn-{index}"),
            completed,
            None,
        );
        let mut file = OpenOptions::new().append(true).open(path).unwrap();
        for _ in 0..16_000 {
            file.write_all(b"{\"type\":\"ignored_event\",\"payload\":{}}\n")
                .unwrap();
        }
    }
    let now = Utc::now() + Duration::minutes(1);
    let mut monitor = source_monitor(temp.path(), roots[0].clone())
        .with_additional_codex_roots(roots[1..].to_vec())
        .unwrap();
    let found = poll_until_idle(&mut monitor, now);
    assert!(found
        .iter()
        .any(|turn| turn.id == turn_id("session-0", "turn-0")));
    for index in 1..4 {
        assert!(
            found
                .iter()
                .any(|turn| turn.id
                    == turn_id(&format!("session-{index}"), &format!("turn-{index}"))),
            "profile {index} did not make progress under the shared budget"
        );
    }
    assert!(monitor.bytes_read_last_poll() <= SourceMonitor::MAX_POLL_BYTES);
}

fn turn_id(session: &str, turn: &str) -> String {
    use sha2::{Digest, Sha256};
    format!(
        "{:x}",
        Sha256::digest(format!("{session}|{turn}").as_bytes())
    )
}

#[test]
fn combined_checkpoints_resume_all_profiles_and_survive_missing_or_partial_profiles() {
    let temp = TestDir::new();
    let default = temp.path().join("default");
    let extra = temp.path().join("extra");
    let completed = Utc::now() - Duration::minutes(30);
    let mtime = SystemTime::now() - StdDuration::from_secs(20 * 60);
    write_turn(
        &default,
        "default-session",
        "turn-1",
        completed,
        Some(mtime),
    );
    write_turn(&extra, "extra-session", "turn-1", completed, Some(mtime));
    let now = Utc::now() + Duration::minutes(1);
    let mut first = source_monitor(temp.path(), default.clone())
        .with_additional_codex_roots(vec![extra.clone()])
        .unwrap();
    let records = poll_until_idle(&mut first, now);
    assert_eq!(records.len(), 2);
    let saved = first.checkpoints(&SourceCheckpoints::default());
    assert_eq!(saved.codex.len(), 2);

    let mut restarted = source_monitor(temp.path(), default.clone())
        .with_additional_codex_roots(vec![extra.clone()])
        .unwrap();
    restarted.set_checkpoints(saved.clone());
    assert!(restarted
        .poll(now + Duration::minutes(1))
        .unwrap()
        .is_empty());
    assert_eq!(restarted.checkpoints(&saved).codex, saved.codex);

    fs::remove_dir_all(&extra).unwrap();
    let mut partial = source_monitor(temp.path(), default)
        .with_additional_codex_roots(vec![extra])
        .unwrap();
    partial.set_checkpoints(saved.clone());
    partial.poll(now + Duration::minutes(2)).unwrap();
    assert!(
        !partial.had_source_error(),
        "a missing root is not a read error"
    );
    assert_eq!(partial.checkpoints(&saved).codex, saved.codex);

    let mut unpolled = source_monitor(temp.path(), temp.path().join("default"))
        .with_additional_codex_roots(vec![temp.path().join("extra")])
        .unwrap();
    unpolled.set_checkpoints(saved.clone());
    assert_eq!(unpolled.checkpoints(&saved).codex, saved.codex);
}
