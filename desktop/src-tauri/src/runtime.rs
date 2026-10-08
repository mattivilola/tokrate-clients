use crate::{
    badge, flyout,
    schedule::{self, PollSignal, Woken},
    watcher::{WatchTarget, Watchers},
    Shared,
};
use chrono::{DateTime, Utc};
use futures_util::StreamExt;
use rand::RngCore;
use serde::{Deserialize, Serialize};
use std::{
    path::PathBuf,
    sync::{Arc, Mutex},
    time::Duration,
};
use tauri::Manager;
use tokrate_core::{
    signed_request, tray_reading, AntigravityMonitor, AutoSelector, History, LiveResponses,
    ModelKey, OpenCodeMonitor, ProviderBadge, ResponseMetric, SelectionMode, SharingQueue,
    SourceChange, SourceCheckpoints, SourceMonitor, TrayReadingKind, TurnMetric, APP_VERSION,
};
use zeroize::Zeroizing;
const API: &str = "https://tokrate.dev/api/public/v1";
pub const SHARING_NOTICE_VERSION: &str = "2026-10-06-v4";
/// While records keep arriving, local history is written at most this often. What is not written
/// yet is safe: the checkpoints are saved with the records they belong to, so after a crash the
/// files behind the unwritten records are read again.
const HISTORY_SAVE_INTERVAL_SECONDS: i64 = 10;
/// Retention pruning looks at most this often.
const HISTORY_PRUNE_INTERVAL_SECONDS: i64 = 600;
/// How long the core keeps turns (`History`'s retention).
const HISTORY_RETENTION_DAYS: i64 = 7;
/// The coding tools the app reads: recorded id, display title and the two-letter chip the tray text
/// and the model picker use (the UI's `CODING_TOOLS`, the Mac app's `CodingTool.known`).
const CODING_TOOLS: [(&str, &str, &str); 5] = [
    ("codex", "Codex", "CX"),
    ("claude-code", "Claude Code", "CC"),
    ("grok-build", "Grok Build", "GB"),
    ("antigravity", "Antigravity", "AG"),
    ("opencode", "OpenCode", "OC"),
];
/// The inference routes of the provider filter (the UI's `ProviderFilter`).
const PROVIDER_FILTERS: [&str; 7] = [
    "openai",
    "anthropic",
    "amazon-bedrock",
    "google-vertex",
    "xai",
    "google",
    "unknown",
];

#[derive(Clone, Copy, Debug, Deserialize, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
enum SharingConsentAction {
    Accepted,
    Declined,
    Withdrawn,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct SharingConsent {
    notice_version: String,
    recorded_at: String,
    action: SharingConsentAction,
}
impl SharingConsent {
    fn notice_is_current(&self) -> bool {
        self.notice_version == SHARING_NOTICE_VERSION
            && chrono::DateTime::parse_from_rfc3339(&self.recorded_at).is_ok()
    }
}

#[derive(Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields, default)]
pub struct Settings {
    pub sharing: bool,
    sharing_consent: Option<SharingConsent>,
    pub monitoring: bool,
    pub show_speed: bool,
    pub selection: String,
    pub show_provider_badge: bool,
    pub show_tool_chip: bool,
    pub days: u8,
    pub root: String,
    pub claude_root: String,
    pub grok_root: String,
    pub antigravity_root: String,
    pub opencode_root: String,
}
impl Default for Settings {
    fn default() -> Self {
        let home = std::env::var_os(if cfg!(windows) { "USERPROFILE" } else { "HOME" })
            .map(PathBuf::from)
            .unwrap_or_else(|| PathBuf::from("."));
        let codex_home = std::env::var_os("CODEX_HOME")
            .map(PathBuf::from)
            .unwrap_or_else(|| home.join(".codex"));
        let claude_home = std::env::var_os("CLAUDE_CONFIG_DIR")
            .map(PathBuf::from)
            .unwrap_or_else(|| home.join(".claude"));
        let grok_home = std::env::var_os("GROK_HOME")
            .map(PathBuf::from)
            .unwrap_or_else(|| home.join(".grok"));
        let opencode_home = opencode_data_dir(std::env::var_os("XDG_DATA_HOME"), &home);
        Self {
            sharing: false,
            sharing_consent: None,
            monitoring: true,
            show_speed: true,
            selection: "auto".into(),
            show_provider_badge: true,
            show_tool_chip: true,
            days: 1,
            root: codex_home.join("sessions").to_string_lossy().into(),
            claude_root: claude_home.join("projects").to_string_lossy().into(),
            grok_root: grok_home.join("sessions").to_string_lossy().into(),
            // Antigravity has no home override: its data folder is always `~/.gemini`.
            antigravity_root: home.join(".gemini").to_string_lossy().into(),
            opencode_root: opencode_home.to_string_lossy().into(),
        }
    }
}
impl Settings {
    fn sharing_authorized(&self) -> bool {
        self.sharing
            && self.sharing_consent.as_ref().is_some_and(|consent| {
                consent.notice_is_current() && consent.action == SharingConsentAction::Accepted
            })
    }
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct SettingsPatch {
    pub sharing: Option<bool>,
    pub monitoring: Option<bool>,
    pub show_speed: Option<bool>,
    pub selection: Option<String>,
    pub show_provider_badge: Option<bool>,
    pub show_tool_chip: Option<bool>,
    pub days: Option<u8>,
}
/// Detected state of one coding-tool log folder, for the Sources settings and first-run welcome.
#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SourceStatus {
    id: &'static str,
    root: String,
    is_default: bool,
    found: bool,
}
#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Snapshot {
    settings: Settings,
    consent_prompt_required: bool,
    records: Vec<TurnMetric>,
    /// Qualifying responses completed since launch, oldest first. Local only, never persisted.
    live: Vec<ResponseMetric>,
    /// The model an Auto selection currently follows; `None` for pinned selections.
    active: Option<ModelKey>,
    status: String,
    monitor_status: String,
    pending: usize,
    board: Option<serde_json::Value>,
    revision: u64,
    records_changed: bool,
    sources: Vec<SourceStatus>,
    smoke: bool,
}
/// The dashboard's coding-tool and provider filters (`None` is "all"). They live in the flyout's
/// webview; the host needs them to show the same value as the hero. Not persisted: the webview
/// starts with "all" and reports its filters again.
#[derive(Clone, Debug, Default, Eq, PartialEq)]
struct DashboardFilters {
    tool: Option<String>,
    provider: Option<String>,
}
pub struct Runtime {
    settings: Settings,
    filters: DashboardFilters,
    consent_prompt_required: bool,
    history: History,
    live: LiveResponses,
    selector: AutoSelector,
    active: Option<ModelKey>,
    monitor: SourceMonitor,
    dir: PathBuf,
    status: String,
    pub monitor_status: String,
    queue: SharingQueue,
    board: Option<serde_json::Value>,
    generation: u64,
    revision: u64,
    network: Option<tauri::async_runtime::JoinHandle<()>>,
    sharing_active: bool,
    smoke: bool,
    history_read_error: bool,
    /// Wakes the poll task: watchers report source changes, settings changes ask for a poll.
    signal: Arc<PollSignal>,
    /// Records or pruning changed the history since it was last written.
    history_unsaved: bool,
    last_history_save: Option<DateTime<Utc>>,
    last_history_prune: Option<DateTime<Utc>>,
    /// The previous poll found data left to read (a replay under way).
    was_busy: bool,
}
/// What one poll leaves for the poll task.
pub struct Polled {
    pub tray: TrayState,
    /// When the next poll is due if nothing wakes it earlier; `None` when nothing is pending.
    pub deadline: Option<DateTime<Utc>>,
    /// When the poll ended.
    pub at: DateTime<Utc>,
}
impl Runtime {
    pub fn load(dir: PathBuf) -> Result<Self, Box<dyn std::error::Error>> {
        std::fs::create_dir_all(&dir)?;
        let (settings, status, consent_prompt_required) =
            match std::fs::read(dir.join("settings.json")) {
                Ok(bytes) => match serde_json::from_slice::<Settings>(&bytes) {
                    Ok(mut s) if [1, 7].contains(&s.days) => {
                        s.selection =
                            SelectionMode::normalize(&s.selection).unwrap_or_else(|| "auto".into());
                        let requires_reconfirmation = s.sharing && !s.sharing_authorized();
                        if requires_reconfirmation {
                            s.sharing = false;
                        }
                        let prompt = requires_reconfirmation
                            && s.sharing_consent
                                .as_ref()
                                .map_or(true, |consent| !consent.notice_is_current());
                        (
                            s,
                            if requires_reconfirmation {
                                "Sharing is off until you review the contribution notice."
                            } else {
                                "Starting…"
                            },
                            prompt,
                        )
                    }
                    _ => (
                        Settings::default(),
                        "Settings could not be read. Sharing is off; review your settings.",
                        false,
                    ),
                },
                Err(e) if e.kind() == std::io::ErrorKind::NotFound => (
                    Settings::default(),
                    "Choose whether Tokrate may contribute measurements.",
                    true,
                ),
                Err(_) => (
                    Settings::default(),
                    "Settings unavailable. Sharing is off.",
                    false,
                ),
            };
        let loaded_history = History::load(&dir.join("history.json"), Utc::now());
        let history_read_error = loaded_history.is_err();
        let history = loaded_history.unwrap_or_default();
        let mut monitor = SourceMonitor::new(
            PathBuf::from(&settings.root),
            PathBuf::from(&settings.claude_root),
            PathBuf::from(&settings.grok_root),
            PathBuf::from(&settings.antigravity_root),
            PathBuf::from(&settings.opencode_root),
        );
        // Files already read to their end by the run that saved this history are not read again.
        monitor.set_checkpoints(history.checkpoints().clone());
        Ok(Self {
            monitor,
            settings,
            filters: DashboardFilters::default(),
            consent_prompt_required,
            history,
            live: LiveResponses::new(Utc::now()),
            selector: AutoSelector::new(),
            active: None,
            dir,
            status: status.into(),
            monitor_status: "Starting monitoring…".into(),
            queue: SharingQueue::new(),
            board: None,
            generation: 0,
            revision: 0,
            network: None,
            sharing_active: false,
            smoke: false,
            history_read_error,
            signal: Arc::new(PollSignal::default()),
            history_unsaved: false,
            last_history_save: None,
            last_history_prune: None,
            was_busy: false,
        })
    }
    pub fn load_smoke(dir: PathBuf) -> Result<Self, Box<dyn std::error::Error>> {
        std::fs::create_dir_all(&dir)?;
        let mut settings = Settings::default();
        settings.sharing = false;
        settings.root = dir.join("sessions").to_string_lossy().into();
        settings.claude_root = dir.join("claude-projects").to_string_lossy().into();
        settings.grok_root = dir.join("grok-sessions").to_string_lossy().into();
        settings.antigravity_root = dir.join("gemini").to_string_lossy().into();
        settings.opencode_root = dir.join("opencode").to_string_lossy().into();
        for root in [
            &settings.root,
            &settings.claude_root,
            &settings.grok_root,
            &settings.antigravity_root,
            &settings.opencode_root,
        ] {
            std::fs::create_dir_all(root)?;
        }
        tokrate_core::write_private_file(
            dir.join("settings.json"),
            &serde_json::to_vec(&settings)?,
        )?;
        let mut result = Self::load(dir)?;
        result.smoke = true;
        Ok(result)
    }
    pub fn finish_smoke(&self) -> Result<(), String> {
        if !self.smoke {
            return Err("Not a smoke run".into());
        }
        if self.settings.sharing
            || self.sharing_active
            || self.board.is_some()
            || ["codex", "claude-code", "grok-build"].iter().any(|client| {
                !self
                    .history
                    .records()
                    .iter()
                    .any(|record| &record.client == client)
            })
        {
            return Err("Smoke state invalid".into());
        }
        tokrate_core::write_private_file(
            self.dir.join("smoke-result.json"),
            b"{\"nativeWebview\":true,\"parsedFixture\":true,\"sharingOff\":true,\"updatesOff\":true}",
        )
        .map_err(|_| "Cannot write smoke result".into())
    }
    pub fn snapshot(&self, since: Option<u64>) -> Snapshot {
        let changed = since != Some(self.revision);
        Snapshot {
            settings: self.settings.clone(),
            consent_prompt_required: self.consent_prompt_required,
            records: if changed {
                self.history.records().to_vec()
            } else {
                vec![]
            },
            live: self.live.responses(),
            active: self.active.clone(),
            status: self.status.clone(),
            monitor_status: self.monitor_status.clone(),
            pending: self.queue.len(),
            board: self.board.clone(),
            revision: self.revision,
            records_changed: changed,
            sources: self.source_statuses(),
            smoke: self.smoke,
        }
    }
    fn source_statuses(&self) -> Vec<SourceStatus> {
        let defaults = Settings::default();
        [
            ("codex", &self.settings.root, &defaults.root),
            (
                "claude-code",
                &self.settings.claude_root,
                &defaults.claude_root,
            ),
            ("grok-build", &self.settings.grok_root, &defaults.grok_root),
            (
                "antigravity",
                &self.settings.antigravity_root,
                &defaults.antigravity_root,
            ),
            (
                "opencode",
                &self.settings.opencode_root,
                &defaults.opencode_root,
            ),
        ]
        .into_iter()
        .map(|(id, root, default)| SourceStatus {
            id,
            root: root.clone(),
            is_default: root == default,
            found: source_found(id, root),
        })
        .collect()
    }
    /// The first-run welcome stays open until the user makes an affirmative or local-only choice.
    pub fn consent_pending(&self) -> bool {
        self.consent_prompt_required
    }
    pub fn is_smoke(&self) -> bool {
        self.smoke
    }
    pub fn show_provider_badge(&self) -> bool {
        self.settings.show_provider_badge
    }
    pub fn signal(&self) -> Arc<PollSignal> {
        self.signal.clone()
    }
    fn save_settings(&self, settings: &Settings) -> Result<(), String> {
        let bytes = serde_json::to_vec_pretty(settings).map_err(|_| "Settings invalid")?;
        tokrate_core::write_private_file(self.dir.join("settings.json"), &bytes)
            .map_err(|_| "Could not save settings".into())
    }
    pub fn update(&mut self, p: SettingsPatch) -> Result<(), String> {
        let mut next = self.settings.clone();
        if let Some(v) = p.sharing {
            if v {
                return Err("Community sharing requires the current informed consent".into());
            }
            if next.sharing {
                next.sharing_consent = Some(SharingConsent {
                    notice_version: SHARING_NOTICE_VERSION.into(),
                    recorded_at: Utc::now().to_rfc3339(),
                    action: SharingConsentAction::Withdrawn,
                });
            }
            next.sharing = false;
        }
        if let Some(v) = p.monitoring {
            next.monitoring = v
        }
        if let Some(v) = p.show_speed {
            next.show_speed = v
        }
        if let Some(v) = p.selection {
            if v.len() > 1000 {
                return Err("Selection too long".into());
            }
            next.selection = SelectionMode::normalize(&v).ok_or("Unsupported selection")?
        }
        if let Some(v) = p.show_provider_badge {
            next.show_provider_badge = v
        }
        if let Some(v) = p.show_tool_chip {
            next.show_tool_chip = v
        }
        if let Some(v) = p.days {
            if ![1, 7].contains(&v) {
                return Err("Unsupported range".into());
            }
            next.days = v
        }
        self.save_settings(&next)?;
        self.settings = next;
        if p.sharing == Some(false) {
            self.stop_sharing();
        }
        // The tray, the monitoring state or the selection may have changed.
        self.signal.request();
        Ok(())
    }
    /// Sets the dashboard's filters, "all" or a tool or provider id, for the tray value.
    pub fn set_dashboard_filters(&mut self, tool: &str, provider: &str) -> Result<(), String> {
        let tool = match tool {
            "all" => None,
            tool if CODING_TOOLS.iter().any(|(id, ..)| *id == tool) => Some(tool.to_owned()),
            _ => return Err("Choose a supported source".into()),
        };
        let provider = match provider {
            "all" => None,
            provider if PROVIDER_FILTERS.contains(&provider) => Some(provider.to_owned()),
            _ => return Err("Choose a supported provider".into()),
        };
        let next = DashboardFilters { tool, provider };
        if next != self.filters {
            self.filters = next;
            self.signal.request();
        }
        Ok(())
    }
    pub fn record_sharing_consent(
        &mut self,
        accepted: bool,
        notice_version: &str,
    ) -> Result<(), String> {
        if notice_version != SHARING_NOTICE_VERSION {
            return Err("Review the current contribution notice before choosing".into());
        }
        if self.smoke && accepted {
            return Err("Smoke runs cannot share".into());
        }
        let mut next = self.settings.clone();
        next.sharing = accepted;
        next.sharing_consent = Some(SharingConsent {
            notice_version: SHARING_NOTICE_VERSION.into(),
            recorded_at: Utc::now().to_rfc3339(),
            action: if accepted {
                SharingConsentAction::Accepted
            } else {
                SharingConsentAction::Declined
            },
        });
        self.save_settings(&next)?;
        self.settings = next;
        self.consent_prompt_required = false;
        self.stop_sharing();
        Ok(())
    }
    fn stop_sharing(&mut self) {
        self.generation += 1;
        if let Some(task) = self.network.take() {
            task.abort();
        }
        self.queue.disable();
        self.board = None;
        self.sharing_active = false;
        self.status = "Local only".into();
    }
    pub fn set_source_root(&mut self, source: &str, root: PathBuf) -> Result<(), String> {
        if !root.is_dir() {
            return Err("Choose an existing folder".into());
        }
        self.apply_source_root(source, root)
    }
    /// Restores the tool's default folder even when it does not exist yet (tool not installed).
    pub fn reset_source_root(&mut self, source: &str) -> Result<(), String> {
        let defaults = Settings::default();
        let root = match source {
            "codex" => defaults.root,
            "claude-code" => defaults.claude_root,
            "grok-build" => defaults.grok_root,
            "antigravity" => defaults.antigravity_root,
            "opencode" => defaults.opencode_root,
            _ => return Err("Choose a supported source".into()),
        };
        self.apply_source_root(source, PathBuf::from(root))
    }
    fn apply_source_root(&mut self, source: &str, root: PathBuf) -> Result<(), String> {
        let mut next = self.settings.clone();
        match source {
            "codex" => next.root = root.to_string_lossy().into(),
            "claude-code" => next.claude_root = root.to_string_lossy().into(),
            "grok-build" => next.grok_root = root.to_string_lossy().into(),
            "antigravity" => next.antigravity_root = root.to_string_lossy().into(),
            "opencode" => next.opencode_root = root.to_string_lossy().into(),
            _ => return Err("Choose a supported source".into()),
        }
        self.save_settings(&next)?;
        self.settings = next;
        self.monitor
            .set_root(source, root)
            .map_err(|_| "Could not start the selected monitor")?;
        // The folder is watched and read from the new place.
        self.signal.request();
        Ok(())
    }
    fn valid(&self, g: u64) -> bool {
        self.settings.sharing_authorized() && self.generation == g
    }
    /// Applies what the folder watchers and settings changes reported since the last call to the
    /// monitors. True when a poll is due because of it. A change that arrives while monitoring is
    /// paused stays noted in the monitors and is read when monitoring resumes.
    pub fn absorb_signal(&mut self) -> bool {
        let wake = self.signal.take();
        let pending = self.monitor.note_changes(&wake.change);
        (pending && self.settings.monitoring) || wake.requested
    }
    /// The source folders to watch, as the monitors read them.
    pub fn watch_targets(&self) -> Vec<WatchTarget> {
        CODING_TOOLS
            .iter()
            .flat_map(|&(source, ..)| self.monitor.watch_folders(source))
            .map(|folder| WatchTarget {
                source: folder.name,
                root: folder.path,
                exists: folder.exists,
                recursive: folder.recursive,
            })
            .collect()
    }
    fn poll_monitor(&mut self) -> Polled {
        let mut polled = self.poll_monitor_at(Utc::now());
        polled.at = Utc::now();
        polled
    }
    fn poll_monitor_at(&mut self, now: DateTime<Utc>) -> Polled {
        self.absorb_signal();
        let mut records = Vec::new();
        let mut failed = false;
        if self.settings.monitoring {
            match self.monitor.poll(now) {
                Ok(found) => {
                    let mut responses = self.monitor.take_live_responses();
                    // Grok Build reports speed per turn only: each of its turns is one live
                    // response, and only turns completed since launch count (`push` drops others).
                    responses.extend(found.iter().filter_map(ResponseMetric::from_grok_turn));
                    self.live.push(responses, now);
                    records = found;
                    failed = self.monitor.had_source_error();
                    if failed {
                        self.monitor_status = "A source folder could not be read. Other available monitors remain active.".into();
                    } else {
                        self.monitor_status = self.source_status();
                    }
                }
                Err(_) => {
                    failed = true;
                    self.monitor_status =
                        "A selected source folder is unavailable. Choose an existing sessions or projects folder."
                            .into()
                }
            }
        } else {
            self.monitor_status = "Monitoring paused".into();
        }
        self.ingest(records, failed, now)
    }
    /// Takes in what a poll found: the active model, sharing, history, saving and the tray.
    fn ingest(&mut self, records: Vec<TurnMetric>, failed: bool, now: DateTime<Utc>) -> Polled {
        self.active = match SelectionMode::parse(&self.settings.selection) {
            Some(SelectionMode::Auto { tool }) => self
                .selector
                .update(now, &self.live.responses(), tool.as_deref())
                .cloned(),
            _ => None,
        };
        if self.sharing_active {
            self.queue.enqueue(&records, now);
        }
        let previous_count = self.history.records().len();
        if !records.is_empty() {
            self.history.merge(&records, now);
            self.last_history_prune = Some(now);
            self.revision += 1;
            self.history_unsaved = true;
        } else if self.prune_is_due(now) {
            self.history.merge(&[], now);
            self.last_history_prune = Some(now);
            if previous_count != self.history.records().len() {
                self.revision += 1;
                self.history_unsaved = true;
            }
        }
        let deadline = if self.settings.monitoring {
            self.monitor.next_poll_deadline(now)
        } else {
            None
        };
        // Data left to read means a replay is under way; the checkpoints it advances are written
        // when it ends, not with every step.
        let busy = deadline.is_some_and(|deadline| deadline <= now);
        let replay_finished = self.was_busy && !busy;
        self.was_busy = busy;
        self.persist_history(now, replay_finished);
        if self.history_read_error {
            self.monitor_status="Monitoring in memory. Saved history is unreadable and preserved; back it up and repair it before restarting.".into();
        }
        if self.smoke {
            let sources: std::collections::HashSet<&str> = self
                .history
                .records()
                .iter()
                .map(|record| record.client.as_str())
                .collect();
            let evidence = serde_json::json!({"records": self.history.records().len(), "sources": sources, "sharing": self.settings.sharing, "monitorStatus": self.monitor_status});
            let _ = tokrate_core::write_private_file(
                self.dir.join("smoke-state.json"),
                evidence.to_string().as_bytes(),
            );
        }
        Polled {
            tray: self.tray_state(now),
            // A failed poll is retried at the normal cadence, and a throttled save is written
            // when it is due.
            deadline: [deadline, failed.then_some(now), self.save_due_at(now)]
                .into_iter()
                .flatten()
                .min(),
            at: now,
        }
    }
    /// Expired turns are pruned when the oldest has crossed the retention, and then at most every
    /// ten minutes: `History::merge` rebuilds the whole history.
    fn prune_is_due(&self, now: DateTime<Utc>) -> bool {
        let cutoff = now - chrono::Duration::days(HISTORY_RETENTION_DAYS);
        // Newest first: the last record is the oldest.
        self.history
            .records()
            .last()
            .is_some_and(|oldest| oldest.completed_at < cutoff)
            && self.last_history_prune.map_or(true, |last| {
                now < last
                    || now - last >= chrono::Duration::seconds(HISTORY_PRUNE_INTERVAL_SECONDS)
            })
    }
    fn save_is_due(&self, now: DateTime<Utc>) -> bool {
        self.history_unsaved
            && self.last_history_save.map_or(true, |last| {
                now < last || now - last >= chrono::Duration::seconds(HISTORY_SAVE_INTERVAL_SECONDS)
            })
    }
    /// When a throttled save falls due.
    fn save_due_at(&self, now: DateTime<Utc>) -> Option<DateTime<Utc>> {
        (self.history_unsaved && !self.history_read_error).then(|| {
            self.last_history_save.map_or(now, |last| {
                last + chrono::Duration::seconds(HISTORY_SAVE_INTERVAL_SECONDS)
            })
        })
    }
    /// What the monitors have read to the end by now, as it is saved with the history.
    fn fresh_checkpoints(&self, now: DateTime<Utc>) -> SourceCheckpoints {
        self.monitor
            .checkpoints(self.history.checkpoints())
            .retained(now)
    }
    /// Writes the history, and with it the checkpoints of the files the monitors have read into it.
    fn save_history(&mut self, checkpoints: SourceCheckpoints, now: DateTime<Utc>) {
        self.history.set_checkpoints(checkpoints, now);
        // A failing disk is tried again after the interval, not at every poll.
        self.last_history_save = Some(now);
        if self.history.save(self.dir.join("history.json")).is_ok() {
            self.history_unsaved = false;
        } else {
            self.monitor_status = "Could not save local history. Check disk access.".into();
        }
    }
    /// Writes the history when it is due, and when a replay has just ended with checkpoints the
    /// saved ones lack. Unreadable history is preserved, never overwritten.
    fn persist_history(&mut self, now: DateTime<Utc>, replay_finished: bool) {
        if self.history_read_error {
            return;
        }
        let due = self.save_is_due(now);
        if !due && !replay_finished {
            return;
        }
        let checkpoints = self.fresh_checkpoints(now);
        if due || checkpoints != *self.history.checkpoints() {
            self.save_history(checkpoints, now);
        }
    }
    /// Writes what the next launch needs when the app quits, so the files read since the last
    /// write are not read again.
    pub fn save_on_exit(&mut self) {
        if self.history_read_error {
            return;
        }
        let now = Utc::now();
        let checkpoints = self.fresh_checkpoints(now);
        if self.history_unsaved || checkpoints != *self.history.checkpoints() {
            self.save_history(checkpoints, now);
        }
    }
    fn tray_state(&self, now: DateTime<Utc>) -> TrayState {
        tray_state(
            &self.settings,
            &self.filters,
            &self.live,
            self.active.as_ref(),
            self.history.records(),
            now,
        )
    }

    fn source_status(&self) -> String {
        let mut sources = Vec::new();
        for (id, name, root) in [
            ("codex", "Codex", &self.settings.root),
            ("claude-code", "Claude Code", &self.settings.claude_root),
            ("grok-build", "Grok Build", &self.settings.grok_root),
            (
                "antigravity",
                "Antigravity",
                &self.settings.antigravity_root,
            ),
            ("opencode", "OpenCode", &self.settings.opencode_root),
        ] {
            if source_found(id, root) {
                sources.push(name);
            }
        }
        if sources.is_empty() {
            "Waiting for a supported coding tool or choose its sessions/projects folder.".into()
        } else {
            format!("Monitoring {}", sources.join(", "))
        }
    }
}
/// OpenCode's data folder: `$XDG_DATA_HOME/opencode`, else `~/.local/share/opencode`, on every
/// platform (Windows included), as OpenCode resolves it itself.
fn opencode_data_dir(xdg_data_home: Option<std::ffi::OsString>, home: &std::path::Path) -> PathBuf {
    xdg_data_home
        .filter(|value| !value.is_empty())
        .map(PathBuf::from)
        .unwrap_or_else(|| home.join(".local").join("share"))
        .join("opencode")
}
/// Whether a tool's data is there: its sessions/projects folder, Antigravity's conversation
/// folders (a bare `~/.gemini` belongs to the Gemini CLI) or OpenCode's `opencode.db`.
fn source_found(id: &str, root: &str) -> bool {
    let root = std::path::Path::new(root);
    match id {
        "antigravity" => AntigravityMonitor::has_conversation_folder(root),
        "opencode" => OpenCodeMonitor::has_database(root),
        _ => root.is_dir(),
    }
}
/// What the tray shows: a headline, a longer tooltip/menu line and the provider badge to draw.
#[derive(Clone, Debug, PartialEq)]
pub struct TrayState {
    pub title: String,
    pub detail: String,
    pub badge: ProviderBadge,
    /// True when a model is resolved, so a provider badge can replace the default icon.
    pub badge_model_known: bool,
}
impl TrayState {
    fn idle() -> Self {
        Self {
            title: "Tokrate".into(),
            detail: "Tokrate".into(),
            badge: ProviderBadge::Unknown,
            badge_model_known: false,
        }
    }
    /// No value: monitoring is paused or nothing was measured in scope.
    fn without_value(detail: &str) -> Self {
        Self {
            title: "—".into(),
            detail: format!("Tokrate · Response speed — · {detail}"),
            ..Self::idle()
        }
    }
}
fn coding_tool(client: &str) -> Option<&'static (&'static str, &'static str, &'static str)> {
    CODING_TOOLS.iter().find(|(id, ..)| *id == client)
}
/// "Claude Code" for `claude-code`; a tool this build does not know is a generic "Coding tool".
fn tool_title(client: &str) -> &'static str {
    coding_tool(client).map_or("Coding tool", |(_, title, _)| title)
}
/// The two-letter chip of a coding tool; an unknown id is chipped by its first two letters.
fn tool_chip(client: &str) -> String {
    coding_tool(client).map_or_else(
        || client.chars().take(2).collect::<String>().to_uppercase(),
        |(_, _, chip)| (*chip).to_owned(),
    )
}
fn speed_text(speed: f64) -> String {
    if speed < 100.0 {
        format!("{speed:.1} tok/s")
    } else {
        format!("{speed:.0} tok/s")
    }
}
/// What the tray shows. The value is the dashboard hero's reading (`tray_reading`, one function
/// for both), so the tray never shows a dash while the flyout has a value. "—" means no
/// measurement in scope, or paused monitoring. The tooltip names the measurement like the Mac
/// menu bar's accessibility label, with the provider and the coding tool; the text beside the
/// icon, where the desktop has one, is led by the coding-tool chip.
fn tray_state(
    settings: &Settings,
    filters: &DashboardFilters,
    live: &LiveResponses,
    active: Option<&ModelKey>,
    turns: &[TurnMetric],
    now: DateTime<Utc>,
) -> TrayState {
    if !settings.show_speed {
        return TrayState::idle();
    }
    if !settings.monitoring {
        return TrayState::without_value("monitoring paused");
    }
    let selection =
        SelectionMode::parse(&settings.selection).unwrap_or(SelectionMode::Auto { tool: None });
    let Some(reading) = tray_reading(
        &selection,
        live,
        active,
        turns,
        filters.tool.as_deref(),
        filters.provider.as_deref(),
        now,
    ) else {
        return TrayState::without_value("no measurement yet");
    };
    let badge = ProviderBadge::of(reading.model.as_deref(), reading.provider.as_deref());
    let speed = speed_text(reading.speed);
    let measure = match reading.kind {
        TrayReadingKind::Live => "Response speed",
        TrayReadingKind::LatestResponse => "Response speed of the latest turn",
        TrayReadingKind::TurnFallback => "Turn speed of the latest turn",
    };
    let provider = (badge != ProviderBadge::Unknown).then(|| badge.label());
    let detail = [
        Some(speed.as_str()),
        Some(measure),
        Some(reading.model.as_deref().unwrap_or("Unknown model")),
        provider,
        Some(tool_title(&reading.client)),
    ]
    .into_iter()
    .flatten()
    .collect::<Vec<_>>()
    .join(" · ");
    let title = if settings.show_tool_chip {
        format!("{} {speed}", tool_chip(&reading.client))
    } else {
        speed
    };
    TrayState {
        title,
        detail,
        badge,
        badge_model_known: true,
    }
}
fn identity() -> Result<Zeroizing<[u8; 32]>, String> {
    let entry = keyring::Entry::new("dev.tokrate.desktop", "contribution-signing-key-v1")
        .map_err(|_| "Secure credential storage unavailable")?;
    match entry.get_secret() {
        Ok(v) => {
            let secret = Zeroizing::new(v);
            let key = <[u8; 32]>::try_from(secret.as_slice())
                .map_err(|_| "Stored signing identity is invalid")?;
            Ok(Zeroizing::new(key))
        }
        Err(keyring::Error::NoEntry) => {
            let mut key = Zeroizing::new([0u8; 32]);
            rand::rngs::OsRng.fill_bytes(key.as_mut());
            entry
                .set_secret(key.as_ref())
                .map_err(|_| "Cannot store signing identity securely")?;
            Ok(key)
        }
        Err(_) => Err("Secure credential storage is locked or unavailable".into()),
    }
}

fn authorized_effect<T>(authorized: bool, effect: impl FnOnce() -> T) -> Option<T> {
    if authorized {
        Some(effect())
    } else {
        None
    }
}

pub fn start_monitor(app: tauri::AppHandle, speed: tauri::menu::MenuItem<tauri::Wry>) {
    let shared = app.state::<Shared>().inner().clone();
    let signal = shared.lock().unwrap().signal();
    tauri::async_runtime::spawn(async move {
        let watchers = Arc::new(Mutex::new(Watchers::default()));
        // The badge, theme and enabled state last applied to the tray icon (`None`: default icon).
        let mut applied_icon: Option<(ProviderBadge, bool)> = None;
        loop {
            let result = {
                let (shared, watchers, signal) = (shared.clone(), watchers.clone(), signal.clone());
                tauri::async_runtime::spawn_blocking(move || {
                    // Before the poll, so a file written once a watcher exists is either reported
                    // by it or already visible to the poll. Starting a recursive watcher walks the
                    // folder, which is why this runs without the runtime lock.
                    let targets = shared.lock().unwrap().watch_targets();
                    {
                        let mut watchers = watchers.lock().unwrap();
                        watchers.sync(&targets, &signal);
                        if watchers.fallback_rescan_due() {
                            signal.report(SourceChange {
                                must_rescan: true,
                                ..SourceChange::default()
                            });
                        }
                    }
                    let mut runtime = shared.lock().unwrap();
                    let polled = runtime.poll_monitor();
                    (polled, runtime.show_provider_badge())
                })
                .await
            };
            let (last_poll, deadline) = match result {
                Ok((polled, show_badge)) => {
                    let state = &polled.tray;
                    let _ = speed.set_text(&state.detail);
                    if let Some(tray) = app.tray_by_id(flyout::TRAY_ID) {
                        let _ = tray.set_tooltip(Some(&state.detail));
                        #[cfg(not(target_os = "windows"))]
                        {
                            let _ = tray.set_title(Some(&state.title));
                        }
                        let dark = app
                            .get_webview_window(flyout::MAIN)
                            .and_then(|window| window.theme().ok())
                            == Some(tauri::Theme::Dark);
                        let wanted =
                            (show_badge && state.badge_model_known).then_some((state.badge, dark));
                        if wanted != applied_icon {
                            let icon = match wanted {
                                Some((badge, dark)) => {
                                    let (rgba, width, height) = badge::render_badge(badge, dark);
                                    Ok(tauri::image::Image::new_owned(rgba, width, height))
                                }
                                None => badge::default_icon(),
                            };
                            if icon.is_ok_and(|icon| tray.set_icon(Some(icon)).is_ok()) {
                                applied_icon = wanted;
                            }
                        }
                    }
                    (polled.at, polled.deadline)
                }
                // A poll that could not run is tried again at the minimum spacing.
                Err(_) => (Utc::now(), Some(Utc::now())),
            };
            // Sleep until the next poll is due, or until a watcher or a settings change reports
            // something a poll must read (observing the minimum spacing either way).
            loop {
                let delay = schedule::poll_delay(Utc::now(), last_poll, deadline);
                if signal.wait(delay).await == Woken::Due {
                    break;
                }
                let shared = shared.clone();
                let due = tauri::async_runtime::spawn_blocking(move || {
                    shared.lock().unwrap().absorb_signal()
                })
                .await
                .unwrap_or(true);
                if due {
                    let now = Utc::now();
                    tokio::time::sleep(schedule::poll_delay(now, last_poll, Some(now))).await;
                    break;
                }
            }
        }
    });
}
pub fn restart_sharing(app: &tauri::AppHandle) {
    let shared = app.state::<Shared>().inner().clone();
    let mut s = shared.lock().unwrap();
    s.generation += 1;
    if let Some(task) = s.network.take() {
        task.abort();
    }
    s.queue.disable();
    s.board = None;
    s.sharing_active = false;
    let Some(generation) = authorized_effect(s.settings.sharing_authorized(), || s.generation)
    else {
        s.status = "Local only".into();
        return;
    };
    s.status = "Opening secure credential storage…".into();
    let inner = shared.clone();
    s.network = Some(tauri::async_runtime::spawn(async move {
        sharing_loop(inner, generation).await
    }));
}
/// The HTTP client of every community request. It identifies itself as `Tokrate/<version>` and
/// nothing else (no library name or version), like the Mac client.
fn sharing_client_builder() -> reqwest::ClientBuilder {
    reqwest::Client::builder()
        .user_agent(format!("Tokrate/{APP_VERSION}"))
        .https_only(true)
        .redirect(reqwest::redirect::Policy::none())
        .timeout(Duration::from_secs(20))
}
async fn sharing_loop(shared: Arc<Mutex<Runtime>>, generation: u64) {
    let identity_loader = {
        let s = shared.lock().unwrap();
        authorized_effect(s.valid(generation), || identity)
    };
    let Some(identity_loader) = identity_loader else {
        return;
    };
    let key = match tauri::async_runtime::spawn_blocking(identity_loader).await {
        Ok(Ok(k)) => k,
        _ => {
            let mut s = shared.lock().unwrap();
            if s.valid(generation) {
                s.status="Sharing unavailable: unlock your credential store, then Retry sharing. Local monitoring continues.".into()
            }
            return;
        }
    };
    {
        let mut s = shared.lock().unwrap();
        if !s.valid(generation) {
            return;
        }
        s.queue.enable(Utc::now());
        s.sharing_active = true;
        s.status = "Sharing new turns".into();
    }
    let client = match sharing_client_builder().build() {
        Ok(c) => c,
        Err(_) => return,
    };
    // Wall-clock time of the last board fetch: the board follows its own cadence, not uploads.
    let mut last_board: Option<DateTime<Utc>> = None;
    loop {
        let batch = {
            let mut s = shared.lock().unwrap();
            if !s.valid(generation) {
                return;
            }
            s.queue.batch(Utc::now())
        };
        if !batch.is_empty() {
            if let Ok(request) = signed_request(&batch, &key, Utc::now()) {
                let upload = {
                    let s = shared.lock().unwrap();
                    authorized_effect(s.valid(generation), || {
                        client
                            .post(format!("{API}/samples"))
                            .header("Content-Type", "application/json")
                            .header("X-Tokrate-Key", request.public_key)
                            .header("X-Tokrate-Signature", request.signature)
                            .body(request.body)
                            .send()
                    })
                };
                let Some(upload) = upload else {
                    return;
                };
                let result = upload.await;
                let mut s = shared.lock().unwrap();
                if !s.valid(generation) {
                    return;
                }
                match result {
                    Ok(r) if r.status().is_success() => {
                        s.queue
                            .ack(&batch.iter().map(|m| m.sample_id).collect::<Vec<_>>());
                        s.status = "Sharing new turns".into()
                    }
                    Ok(r) if r.status().as_u16() == 426 => {
                        s.queue.disable();
                        s.sharing_active = false;
                        s.board = None;
                        s.status = "Update Tokrate before sharing again. Open Application updates and check for a newer version.".into();
                        return;
                    }
                    Ok(r) if [400, 413, 422].contains(&r.status().as_u16()) => {
                        s.queue
                            .ack(&batch.iter().map(|m| m.sample_id).collect::<Vec<_>>());
                        s.status = "Some reports were rejected. Local history is safe.".into()
                    }
                    _ => s.status = "Upload unavailable. Retrying while sharing is on.".into(),
                }
            }
        }
        if schedule::board_due(Utc::now(), last_board) {
            let board_request = {
                let s = shared.lock().unwrap();
                authorized_effect(s.valid(generation), || fetch_board(&client))
            };
            let Some(board_request) = board_request else {
                return;
            };
            let board = board_request.await;
            {
                let mut s = shared.lock().unwrap();
                if !s.valid(generation) {
                    return;
                }
                s.board = board.ok();
                if s.board.is_none() {
                    s.status = "Community unavailable. Local monitoring continues.".into()
                }
            }
            last_board = Some(Utc::now());
        }
        // Samples whose five-minute period has not ended wait in the queue; the loop wakes when the
        // next one becomes eligible, or for the board, whichever is first.
        let next_upload = {
            let s = shared.lock().unwrap();
            if !s.valid(generation) {
                return;
            }
            s.queue.next_eligible_after(Utc::now())
        };
        tokio::time::sleep(schedule::sharing_delay(Utc::now(), last_board, next_upload)).await;
    }
}
async fn fetch_board(client: &reqwest::Client) -> Result<serde_json::Value, ()> {
    let response = client
        .get(format!("{API}/board"))
        .send()
        .await
        .map_err(|_| ())?;
    if response.status() != 200 {
        return Err(());
    }
    let mut bytes = vec![];
    let mut chunks = response.bytes_stream();
    while let Some(chunk) = chunks.next().await {
        let chunk = chunk.map_err(|_| ())?;
        if bytes.len() + chunk.len() > 1_048_576 {
            return Err(());
        }
        bytes.extend_from_slice(&chunk)
    }
    let value: serde_json::Value = serde_json::from_slice(&bytes).map_err(|_| ())?;
    if value["schemaVersion"] != 1 || !value["cohorts"].is_array() {
        return Err(());
    }
    Ok(value)
}

#[cfg(test)]
mod tests {
    use super::*;
    fn temporary() -> PathBuf {
        let p = std::env::temp_dir().join(format!("tokrate-host-test-{}", rand::random::<u64>()));
        std::fs::create_dir_all(&p).unwrap();
        p
    }
    /// What the sharing client puts on the wire: a local plain-HTTP server records the header
    /// lines of one GET and one POST (the https-only rule is lifted for the test only).
    #[tokio::test]
    async fn sharing_requests_identify_only_as_tokrate_with_the_app_version() {
        use std::io::{Read, Write};
        let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let address = listener.local_addr().unwrap();
        let server = std::thread::spawn(move || {
            let mut requests = Vec::new();
            for _ in 0..2 {
                let (mut stream, _) = listener.accept().unwrap();
                let mut received = Vec::new();
                let mut buffer = [0_u8; 1024];
                while !received.windows(4).any(|window| window == b"\r\n\r\n") {
                    let count = stream.read(&mut buffer).unwrap();
                    received.extend_from_slice(&buffer[..count]);
                }
                stream
                    .write_all(b"HTTP/1.1 200 OK\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
                    .unwrap();
                requests.push(String::from_utf8(received).unwrap());
            }
            requests
        });
        let client = sharing_client_builder().https_only(false).build().unwrap();
        let base = format!("http://{address}");
        client.get(format!("{base}/board")).send().await.unwrap();
        client
            .post(format!("{base}/samples"))
            .header("Content-Type", "application/json")
            .header("X-Tokrate-Key", "key")
            .header("X-Tokrate-Signature", "signature")
            .body("{}")
            .send()
            .await
            .unwrap();
        let requests = server.join().unwrap();
        for (request, expected) in [
            (&requests[0], vec!["accept", "host", "user-agent"]),
            (
                &requests[1],
                vec![
                    "accept",
                    "content-length",
                    "content-type",
                    "host",
                    "user-agent",
                    "x-tokrate-key",
                    "x-tokrate-signature",
                ],
            ),
        ] {
            let mut names = Vec::new();
            let mut user_agents = Vec::new();
            for line in request.lines().skip(1).take_while(|line| !line.is_empty()) {
                let (name, value) = line.split_once(':').unwrap();
                names.push(name.to_ascii_lowercase());
                if name.eq_ignore_ascii_case("user-agent") {
                    user_agents.push(value.trim().to_owned());
                }
            }
            names.sort();
            assert_eq!(names, expected, "{request}");
            assert_eq!(user_agents, [format!("Tokrate/{APP_VERSION}")]);
        }
        assert!(!requests.concat().contains("reqwest"));
    }
    #[cfg(unix)]
    #[test]
    fn saved_settings_are_readable_by_their_owner_only() {
        use std::os::unix::fs::PermissionsExt;
        let dir = temporary();
        let mut runtime = Runtime::load(dir.clone()).unwrap();
        let path = dir.join("settings.json");
        runtime
            .update(serde_json::from_value(serde_json::json!({"showSpeed": false})).unwrap())
            .unwrap();
        assert_eq!(
            std::fs::metadata(&path).unwrap().permissions().mode() & 0o777,
            0o600
        );
        // Settings an older version left with wider permissions are tightened by the next save.
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o644)).unwrap();
        runtime
            .update(serde_json::from_value(serde_json::json!({"showSpeed": true})).unwrap())
            .unwrap();
        assert_eq!(
            std::fs::metadata(&path).unwrap().permissions().mode() & 0o777,
            0o600
        );
        std::fs::remove_dir_all(dir).unwrap();
    }
    #[test]
    fn sources_report_folder_state_and_reset_restores_the_default() {
        let dir = temporary();
        let mut runtime = Runtime::load(dir.clone()).unwrap();
        let custom = dir.join("custom-codex");
        std::fs::create_dir_all(&custom).unwrap();
        runtime.set_source_root("codex", custom.clone()).unwrap();
        let sources = runtime.snapshot(None).sources;
        let codex = sources.iter().find(|s| s.id == "codex").unwrap();
        assert!(!codex.is_default);
        assert!(codex.found);
        assert_eq!(codex.root, custom.to_string_lossy());
        assert_eq!(sources.len(), 5);
        runtime.reset_source_root("codex").unwrap();
        let sources = runtime.snapshot(None).sources;
        let codex = sources.iter().find(|s| s.id == "codex").unwrap();
        assert!(codex.is_default);
        assert!(runtime.reset_source_root("unknown").is_err());
        assert!(runtime
            .set_source_root("codex", dir.join("missing"))
            .is_err());
        std::fs::remove_dir_all(dir).unwrap();
    }
    #[test]
    fn fresh_install_is_local_and_shows_the_contribution_choice() {
        let dir = temporary();
        let runtime = Runtime::load(dir.clone()).unwrap();
        assert!(!runtime.settings.sharing);
        assert!(runtime.consent_prompt_required);
        assert!(!runtime.settings.sharing_authorized());

        let mut identity_reads = 0;
        let mut community_requests = 0;
        assert!(
            authorized_effect(runtime.settings.sharing_authorized(), || identity_reads +=
                1)
            .is_none()
        );
        assert!(
            authorized_effect(runtime.settings.sharing_authorized(), || {
                community_requests += 1
            })
            .is_none()
        );
        assert_eq!(identity_reads, 0);
        assert_eq!(community_requests, 0);
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn legacy_default_on_is_disabled_until_reconfirmed_but_saved_off_stays_quiet() {
        let dir = temporary();
        let mut legacy_on = Settings::default();
        legacy_on.sharing = true;
        std::fs::write(
            dir.join("settings.json"),
            serde_json::to_vec(&legacy_on).unwrap(),
        )
        .unwrap();
        let runtime = Runtime::load(dir.clone()).unwrap();
        assert!(!runtime.settings.sharing);
        assert!(runtime.consent_prompt_required);
        assert!(!runtime.sharing_active);
        assert!(runtime.board.is_none());

        let mut legacy_off = Settings::default();
        legacy_off.sharing = false;
        std::fs::write(
            dir.join("settings.json"),
            serde_json::to_vec(&legacy_off).unwrap(),
        )
        .unwrap();
        let runtime = Runtime::load(dir.clone()).unwrap();
        assert!(!runtime.settings.sharing);
        assert!(!runtime.consent_prompt_required);
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn accepted_choice_is_versioned_persisted_and_withdrawal_requires_reacceptance() {
        let dir = temporary();
        let mut runtime = Runtime::load(dir.clone()).unwrap();
        assert!(runtime.consent_prompt_required);
        assert!(runtime
            .record_sharing_consent(true, "stale-notice")
            .is_err());
        runtime
            .record_sharing_consent(true, SHARING_NOTICE_VERSION)
            .unwrap();
        assert!(runtime.settings.sharing_authorized());
        assert!(runtime.settings.sharing);
        assert!(!runtime.consent_prompt_required);
        let saved: serde_json::Value =
            serde_json::from_slice(&std::fs::read(dir.join("settings.json")).unwrap()).unwrap();
        assert_eq!(
            saved["sharingConsent"]["noticeVersion"],
            SHARING_NOTICE_VERSION
        );
        assert_eq!(saved["sharingConsent"]["action"], "accepted");
        assert!(!saved["sharingConsent"]["recordedAt"]
            .as_str()
            .unwrap()
            .is_empty());

        let mut patch = serde_json::from_value(serde_json::json!({"sharing": false})).unwrap();
        runtime.update(patch).unwrap();
        assert!(!runtime.settings.sharing_authorized());
        assert_eq!(
            runtime.settings.sharing_consent.as_ref().unwrap().action,
            SharingConsentAction::Withdrawn
        );
        patch = serde_json::from_value(serde_json::json!({"sharing": true})).unwrap();
        assert!(runtime.update(patch).is_err());
        assert!(!runtime.settings.sharing);
        assert!(!Runtime::load(dir.clone()).unwrap().consent_prompt_required);

        runtime
            .record_sharing_consent(true, SHARING_NOTICE_VERSION)
            .unwrap();
        assert!(runtime.settings.sharing_authorized());
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn declining_is_saved_and_does_not_prompt_again_at_launch() {
        let dir = temporary();
        let mut runtime = Runtime::load(dir.clone()).unwrap();
        runtime
            .record_sharing_consent(false, SHARING_NOTICE_VERSION)
            .unwrap();
        let runtime = Runtime::load(dir.clone()).unwrap();
        assert!(!runtime.settings.sharing);
        assert!(!runtime.consent_prompt_required);
        let consent = runtime.settings.sharing_consent.unwrap();
        assert_eq!(consent.action, SharingConsentAction::Declined);
        assert_eq!(consent.notice_version, SHARING_NOTICE_VERSION);
        assert!(!consent.recorded_at.is_empty());
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn corrupt_consent_cannot_enable_a_legacy_setting() {
        let dir = temporary();
        std::fs::write(
            dir.join("settings.json"),
            br#"{"sharing":true,"sharingConsent":{"noticeVersion":"2026-10-04-v1","recordedAt":"not-a-time","action":"accepted"},"monitoring":true,"showSpeed":true,"selection":"latest","days":1,"root":"","claudeRoot":"","grokRoot":""}"#,
        )
        .unwrap();
        let runtime = Runtime::load(dir.clone()).unwrap();
        assert!(!runtime.settings.sharing);
        assert!(!runtime.settings.sharing_authorized());
        assert!(!runtime.sharing_active);
        assert!(runtime.consent_prompt_required);
        assert!(runtime.board.is_none());
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn persisted_off_and_corrupt_preferences_fail_closed() {
        let dir = temporary();
        let mut settings = Settings::default();
        settings.sharing = false;
        std::fs::write(
            dir.join("settings.json"),
            serde_json::to_vec(&settings).unwrap(),
        )
        .unwrap();
        let runtime = Runtime::load(dir.clone()).unwrap();
        assert!(!runtime.settings.sharing);
        assert!(!runtime.sharing_active);
        assert!(runtime.board.is_none());
        std::fs::write(dir.join("settings.json"), b"{broken").unwrap();
        let runtime = Runtime::load(dir.clone()).unwrap();
        assert!(!runtime.settings.sharing);
        assert!(runtime.status.contains("could not be read"));
        std::fs::remove_dir_all(dir).unwrap();
    }
    #[test]
    fn stale_generation_cannot_restore_community_state() {
        let dir = temporary();
        let mut runtime = Runtime::load(dir.clone()).unwrap();
        runtime
            .record_sharing_consent(true, SHARING_NOTICE_VERSION)
            .unwrap();
        runtime.generation = 7;
        assert!(runtime.valid(7));
        assert!(!runtime.valid(6));
        runtime.settings.sharing = false;
        assert!(!runtime.valid(7));
        std::fs::remove_dir_all(dir).unwrap();
    }
    #[test]
    fn smoke_mode_cannot_enable_network_sharing() {
        let dir = temporary();
        let mut runtime = Runtime::load_smoke(dir.clone()).unwrap();
        let patch = serde_json::from_value(serde_json::json!({"sharing":true})).unwrap();
        assert!(runtime.update(patch).is_err());
        assert!(runtime
            .record_sharing_consent(true, SHARING_NOTICE_VERSION)
            .is_err());
        assert!(!runtime.settings.sharing);
        std::fs::remove_dir_all(dir).unwrap();
    }
    #[test]
    fn opencode_data_folder_follows_xdg_data_home_else_the_home_folder() {
        let home = std::path::Path::new("/home/user");
        assert_eq!(
            opencode_data_dir(None, home),
            home.join(".local").join("share").join("opencode")
        );
        assert_eq!(
            opencode_data_dir(Some("".into()), home),
            home.join(".local").join("share").join("opencode")
        );
        assert_eq!(
            opencode_data_dir(Some("/data".into()), home),
            PathBuf::from("/data").join("opencode")
        );
    }
    #[test]
    fn a_source_is_found_by_its_own_marker_not_by_a_bare_folder() {
        let dir = temporary();
        let root = dir.join("root");
        std::fs::create_dir_all(&root).unwrap();
        let root = root.to_string_lossy().into_owned();
        assert!(source_found("codex", &root));
        assert!(!source_found("antigravity", &root));
        assert!(!source_found("opencode", &root));
        std::fs::write(std::path::Path::new(&root).join("opencode.db"), b"").unwrap();
        assert!(source_found("opencode", &root));
        std::fs::create_dir_all(std::path::Path::new(&root).join("antigravity/conversations"))
            .unwrap();
        assert!(source_found("antigravity", &root));
        std::fs::remove_dir_all(dir).unwrap();
    }
    #[test]
    fn smoke_mode_uses_only_temporary_source_roots_and_stays_local() {
        let dir = temporary();
        let runtime = Runtime::load_smoke(dir.clone()).unwrap();
        let roots = [
            PathBuf::from(&runtime.settings.root),
            PathBuf::from(&runtime.settings.claude_root),
            PathBuf::from(&runtime.settings.grok_root),
            PathBuf::from(&runtime.settings.antigravity_root),
            PathBuf::from(&runtime.settings.opencode_root),
        ];
        assert_eq!(
            roots,
            [
                dir.join("sessions"),
                dir.join("claude-projects"),
                dir.join("grok-sessions"),
                dir.join("gemini"),
                dir.join("opencode")
            ]
        );
        assert!(roots
            .iter()
            .all(|root| root.is_dir() && root.starts_with(&dir)));
        assert!(!runtime.settings.sharing);
        assert!(!runtime.sharing_active);
        assert_eq!(runtime.queue.len(), 0);
        std::fs::remove_dir_all(dir).unwrap();
    }
    #[test]
    fn primary_turns_are_shared_once_and_only_when_their_delegated_output_is_final() {
        let dir = temporary();
        let mut runtime = Runtime::load_smoke(dir.clone()).unwrap();
        let now = Utc::now();
        let stamp = |minutes: i64| {
            (now - chrono::Duration::minutes(minutes))
                .to_rfc3339_opts(chrono::SecondsFormat::Secs, true)
        };
        let line = |kind: &str,
                    at: String,
                    id: &str,
                    agent: Option<&str>,
                    stop: &str,
                    tokens: i64| {
            let mut record = serde_json::json!({
                "type": kind, "timestamp": at, "isSidechain": agent.is_some(),
                "userType": "external", "sessionId": "session-shared", "uuid": id,
                "message": {
                    "id": id, "role": kind, "model": "claude-model", "stop_reason": stop,
                    "content": if kind == "user" { serde_json::json!("synthetic") } else { serde_json::json!([]) },
                    "usage": {"output_tokens": tokens}
                }
            });
            if let Some(agent) = agent {
                record["agentId"] = agent.into();
            }
            record.to_string() + "\n"
        };
        let project = dir.join("claude-projects").join("project-a");
        let subagents = project.join("session-shared").join("subagents");
        std::fs::create_dir_all(&subagents).unwrap();
        std::fs::write(
            project.join("session-shared.jsonl"),
            line("user", stamp(6), "main-user", None, "", 0)
                + &line("assistant", stamp(5), "main-call", None, "end_turn", 500),
        )
        .unwrap();
        std::fs::write(
            subagents.join("agent-helper.jsonl"),
            line("user", stamp(6), "helper-user", Some("helper"), "", 0)
                + &line(
                    "assistant",
                    stamp(5),
                    "helper-call",
                    Some("helper"),
                    "end_turn",
                    120,
                ),
        )
        .unwrap();
        runtime.queue.enable(now - chrono::Duration::minutes(10));
        runtime.sharing_active = true;

        let mut queued_before_final = 0;
        let mut final_polls = 0;
        for _ in 0..12 {
            runtime.poll_monitor();
            let turn = runtime
                .history
                .records()
                .iter()
                .find(|record| record.source_kind.as_deref() == Some("primary"));
            match turn.and_then(|turn| turn.delegated_output_tokens) {
                None => queued_before_final += runtime.queue.len(),
                Some(_) => final_polls += 1,
            }
        }
        // Nothing is shared while attribution is open; the final record is shared exactly once,
        // and the subagent turn is shared as before.
        assert_eq!(queued_before_final, 0);
        assert!(final_polls > 0, "the turn never became final");
        let turn = runtime
            .history
            .records()
            .iter()
            .find(|record| record.source_kind.as_deref() == Some("primary"))
            .unwrap();
        assert_eq!(turn.delegated_output_tokens, Some(120));
        // Queued just now, the samples leave at the next five-minute boundary plus a delay.
        let shared = runtime
            .queue
            .batch(Utc::now() + chrono::Duration::minutes(7));
        let mut kinds: Vec<(&str, Option<i64>)> = shared
            .iter()
            .map(|sample| (sample.source_kind.as_str(), sample.delegated_output_tokens))
            .collect();
        kinds.sort();
        assert_eq!(kinds, [("primary", Some(120)), ("subagent", None)]);
        std::fs::remove_dir_all(dir).unwrap();
    }
    #[test]
    fn corrupt_history_remains_preserved_while_monitoring_continues() {
        let dir = temporary();
        let original = b"{history needing recovery";
        std::fs::write(dir.join("history.json"), original).unwrap();
        let mut runtime = Runtime::load_smoke(dir.clone()).unwrap();
        runtime.poll_monitor();
        assert!(runtime.history_read_error);
        assert!(runtime.monitor_status.contains("preserved"));
        assert_eq!(std::fs::read(dir.join("history.json")).unwrap(), original);
        std::fs::remove_dir_all(dir).unwrap();
    }
    fn write_settings(dir: &std::path::Path, json: serde_json::Value) {
        std::fs::write(dir.join("settings.json"), json.to_string()).unwrap();
    }
    const OLD_NOTICE: &str = "2026-10-04-v1";
    const PREVIOUS_NOTICE: &str = "2026-10-05-v2";
    fn saved_settings(sharing: bool, consent: Option<(&str, &str)>) -> serde_json::Value {
        let mut settings = serde_json::to_value(Settings::default()).unwrap();
        settings["sharing"] = sharing.into();
        settings["sharingConsent"] = consent.map_or(serde_json::Value::Null, |(version, action)| {
            serde_json::json!({"noticeVersion": version, "recordedAt": Utc::now().to_rfc3339(), "action": action})
        });
        settings
    }
    #[test]
    fn notice_version_three_pauses_sharing_that_was_accepted_under_earlier_versions() {
        assert_eq!(SHARING_NOTICE_VERSION, "2026-10-06-v4");
        for old in [OLD_NOTICE, PREVIOUS_NOTICE] {
            assert_ne!(SHARING_NOTICE_VERSION, old);
            let dir = temporary();
            write_settings(&dir, saved_settings(true, Some((old, "accepted"))));
            let runtime = Runtime::load(dir.clone()).unwrap();
            assert!(!runtime.settings.sharing, "{old}");
            assert!(!runtime.settings.sharing_authorized());
            assert!(runtime.consent_prompt_required);
            assert!(!runtime.sharing_active);
            assert!(runtime.board.is_none());
            assert_eq!(runtime.queue.len(), 0);
            std::fs::remove_dir_all(dir).unwrap();
        }
    }
    #[test]
    fn saved_off_choices_stay_off_without_a_prompt_when_the_notice_changes() {
        let dir = temporary();
        for consent in [
            None,
            Some((OLD_NOTICE, "declined")),
            Some((OLD_NOTICE, "withdrawn")),
            Some((OLD_NOTICE, "accepted")),
            Some((PREVIOUS_NOTICE, "declined")),
            Some((PREVIOUS_NOTICE, "withdrawn")),
            Some((PREVIOUS_NOTICE, "accepted")),
        ] {
            write_settings(&dir, saved_settings(false, consent));
            let runtime = Runtime::load(dir.clone()).unwrap();
            assert!(!runtime.settings.sharing);
            assert!(!runtime.consent_prompt_required, "{consent:?}");
            assert!(!runtime.sharing_active);
        }
        std::fs::remove_dir_all(dir).unwrap();
    }
    #[test]
    fn current_consent_keeps_sharing_authorized() {
        let dir = temporary();
        write_settings(
            &dir,
            saved_settings(true, Some((SHARING_NOTICE_VERSION, "accepted"))),
        );
        let runtime = Runtime::load(dir.clone()).unwrap();
        assert!(runtime.settings.sharing_authorized());
        assert!(!runtime.consent_prompt_required);
        std::fs::remove_dir_all(dir).unwrap();
    }
    #[test]
    fn selection_defaults_to_auto_and_migrates_legacy_values() {
        assert_eq!(Settings::default().selection, "auto");
        let dir = temporary();
        for (stored, expected) in [
            ("latest", "auto"),
            ("auto", "auto"),
            ("auto:codex", "auto:codex"),
            ("all", "all"),
            (
                "model:[\"gpt-5\",\"openai\"]",
                "model:[\"gpt-5\",\"openai\"]",
            ),
            ("[1,2,3,4,5,6,7,8]", "auto"),
            ("garbage", "auto"),
        ] {
            let mut settings = saved_settings(false, None);
            settings["selection"] = stored.into();
            write_settings(&dir, settings);
            assert_eq!(
                Runtime::load(dir.clone()).unwrap().settings.selection,
                expected
            );
        }
        let nine = r#"["codex",null,"p","m","gpt-5","openai",null,"high",null]"#;
        let mut settings = saved_settings(false, None);
        settings["selection"] = nine.into();
        write_settings(&dir, settings);
        assert_eq!(Runtime::load(dir.clone()).unwrap().settings.selection, nine);
        std::fs::remove_dir_all(dir).unwrap();
    }
    #[test]
    fn selection_patches_are_validated_and_stored_normalized() {
        let dir = temporary();
        let mut runtime = Runtime::load(dir.clone()).unwrap();
        let patch = |selection: &str| -> SettingsPatch {
            serde_json::from_value(serde_json::json!({ "selection": selection })).unwrap()
        };
        runtime.update(patch("auto:claude-code")).unwrap();
        assert_eq!(runtime.settings.selection, "auto:claude-code");
        runtime.update(patch("latest")).unwrap();
        assert_eq!(runtime.settings.selection, "auto");
        for invalid in ["auto:vim", "model:[1]", "[1,2,3]", "nonsense"] {
            assert_eq!(
                runtime.update(patch(invalid)),
                Err("Unsupported selection".into())
            );
        }
        assert_eq!(runtime.settings.selection, "auto");
        std::fs::remove_dir_all(dir).unwrap();
    }
    #[test]
    fn provider_badge_defaults_on_loads_when_absent_and_is_patchable() {
        assert!(Settings::default().show_provider_badge);
        let dir = temporary();
        let mut settings = saved_settings(false, None);
        settings
            .as_object_mut()
            .unwrap()
            .remove("showProviderBadge");
        write_settings(&dir, settings);
        let mut runtime = Runtime::load(dir.clone()).unwrap();
        assert!(runtime.show_provider_badge());
        let patch =
            serde_json::from_value(serde_json::json!({"showProviderBadge": false})).unwrap();
        runtime.update(patch).unwrap();
        assert!(!runtime.show_provider_badge());
        let saved: serde_json::Value =
            serde_json::from_slice(&std::fs::read(dir.join("settings.json")).unwrap()).unwrap();
        assert_eq!(saved["showProviderBadge"], false);
        assert!(!Runtime::load(dir.clone()).unwrap().show_provider_badge());
        std::fs::remove_dir_all(dir).unwrap();
    }

    fn response(
        id: &str,
        completed_at: DateTime<Utc>,
        model: &str,
        client: &str,
        speed: i64,
    ) -> ResponseMetric {
        ResponseMetric {
            id: id.into(),
            completed_at,
            model: Some(model.into()),
            provider: None,
            client: client.into(),
            source_kind: None,
            metric_version: "response-v1".into(),
            reasoning_effort: None,
            output_tokens: speed * 10,
            duration_seconds: 10.0,
        }
    }
    fn turn(id: &str, client: &str, model: &str, now: DateTime<Utc>) -> TurnMetric {
        let mut turn = TurnMetric::new(
            id.into(),
            now,
            Some(model.into()),
            200,
            10.0,
            None,
            20.0,
            None,
            None,
            None,
            None,
            None,
            None,
        );
        turn.client = client.into();
        turn
    }
    fn live_at(
        started: DateTime<Utc>,
        responses: Vec<ResponseMetric>,
        now: DateTime<Utc>,
    ) -> LiveResponses {
        let mut live = LiveResponses::new(started);
        live.push(responses, now);
        live
    }
    fn no_filters() -> DashboardFilters {
        DashboardFilters::default()
    }
    fn filters(tool: Option<&str>, provider: Option<&str>) -> DashboardFilters {
        DashboardFilters {
            tool: tool.map(str::to_owned),
            provider: provider.map(str::to_owned),
        }
    }
    fn state_with(
        settings: Settings,
        filters: &DashboardFilters,
        live: &LiveResponses,
        active: Option<&ModelKey>,
        turns: &[TurnMetric],
        now: DateTime<Utc>,
    ) -> TrayState {
        tray_state(&settings, filters, live, active, turns, now)
    }
    fn state(
        selection: &str,
        live: &LiveResponses,
        active: Option<&ModelKey>,
        turns: &[TurnMetric],
        now: DateTime<Utc>,
    ) -> TrayState {
        let settings = Settings {
            selection: selection.into(),
            ..Settings::default()
        };
        state_with(settings, &no_filters(), live, active, turns, now)
    }
    /// A model without a known route, as the selector reports it.
    fn key(model: &str) -> ModelKey {
        ModelKey {
            model: Some(model.into()),
            provider: Some("unknown".into()),
        }
    }
    /// A turn with response timing: `tokens` over `seconds` of the model responding.
    fn timed_turn(
        id: &str,
        client: &str,
        model: &str,
        provider: Option<&str>,
        at: DateTime<Utc>,
        response: (i64, f64),
    ) -> TurnMetric {
        let mut turn = turn(id, client, model, at);
        turn.provider = provider.map(str::to_owned);
        turn.response_output_tokens = Some(response.0);
        turn.response_duration_seconds = Some(response.1);
        turn.response_count = Some(1);
        turn
    }
    #[test]
    fn tray_shows_the_median_of_the_newest_five_responses() {
        let now = Utc::now();
        let started = now - chrono::Duration::hours(1);
        let responses = [10, 20, 30, 40, 50, 60]
            .iter()
            .enumerate()
            .map(|(index, speed)| {
                let at = now - chrono::Duration::minutes(6 - index as i64);
                response(
                    &format!("r{index}"),
                    at,
                    "claude-opus-4",
                    "claude-code",
                    *speed,
                )
            })
            .collect();
        let live = live_at(started, responses, now);
        let shown = state("auto", &live, Some(&key("claude-opus-4")), &[], now);
        assert_eq!(shown.title, "CC 40.0 tok/s");
        assert_eq!(
            shown.detail,
            "40.0 tok/s · Response speed · claude-opus-4 · Anthropic · Claude Code"
        );
        assert_eq!(shown.badge, ProviderBadge::Anthropic);
        assert!(shown.badge_model_known);
        // Three digits drop the decimal.
        let fast = live_at(
            started,
            vec![response("f", now, "gpt-5", "codex", 123)],
            now,
        );
        assert_eq!(
            state("model:[\"gpt-5\",null]", &fast, None, &[], now).title,
            "CX 123 tok/s"
        );
    }
    #[test]
    fn the_tool_chip_leads_the_tray_text_unless_it_is_switched_off() {
        let now = Utc::now();
        let live = live_at(
            now - chrono::Duration::hours(1),
            vec![
                response("a", now, "gpt-5", "codex", 40),
                response("b", now, "grok-4", "grok-build", 40),
            ],
            now,
        );
        let shown = |client: &str, chip: bool| {
            let live = live_at(
                now - chrono::Duration::hours(1),
                vec![response("a", now, "some-model", client, 40)],
                now,
            );
            let settings = Settings {
                show_tool_chip: chip,
                ..Settings::default()
            };
            state_with(
                settings,
                &no_filters(),
                &live,
                Some(&key("some-model")),
                &[],
                now,
            )
        };
        assert_eq!(shown("codex", true).title, "CX 40.0 tok/s");
        assert_eq!(shown("claude-code", true).title, "CC 40.0 tok/s");
        assert_eq!(shown("grok-build", true).title, "GB 40.0 tok/s");
        // A tool this build does not know is chipped by its first two letters.
        assert_eq!(shown("vim-agent", true).title, "VI 40.0 tok/s");
        // Off: the text is the speed alone, and the tooltip still names the tool.
        let off = shown("codex", false);
        assert_eq!(off.title, "40.0 tok/s");
        assert!(off.detail.ends_with("· Codex"), "{}", off.detail);
        let _ = live;
    }
    #[test]
    fn tray_shows_the_latest_turn_when_the_newest_live_response_is_older_than_ten_minutes() {
        let now = Utc::now();
        let started = now - chrono::Duration::hours(1);
        let stale = response(
            "old",
            now - chrono::Duration::minutes(11),
            "gpt-5",
            "codex",
            50,
        );
        let live = live_at(started, vec![stale], now);
        // Nothing measured at all: a dash and no badge.
        let none = state("auto", &live, Some(&key("gpt-5")), &[], now);
        assert_eq!(none.title, "—");
        assert_eq!(
            none.detail,
            "Tokrate · Response speed — · no measurement yet"
        );
        assert!(!none.badge_model_known);
        let empty = state("auto", &LiveResponses::new(started), None, &[], now);
        assert_eq!(empty.title, "—");
        // The model's latest turn with response timing: 900 tokens in 12 s.
        let turns = [timed_turn(
            "t",
            "codex",
            "gpt-5",
            None,
            now - chrono::Duration::minutes(30),
            (900, 12.0),
        )];
        let latest = state("auto", &live, Some(&key("gpt-5")), &turns, now);
        assert_eq!(latest.title, "CX 75.0 tok/s");
        assert_eq!(
            latest.detail,
            "75.0 tok/s · Response speed of the latest turn · gpt-5 · OpenAI · Codex"
        );
        assert_eq!(latest.badge, ProviderBadge::OpenAi);
        assert!(latest.badge_model_known);
        // Without response timing anywhere: the whole-turn speed, named as such.
        let plain = [turn(
            "p",
            "codex",
            "gpt-5",
            now - chrono::Duration::minutes(30),
        )];
        let fallback = state("auto", &live, Some(&key("gpt-5")), &plain, now);
        assert_eq!(fallback.title, "CX 20.0 tok/s");
        assert_eq!(
            fallback.detail,
            "20.0 tok/s · Turn speed of the latest turn · gpt-5 · OpenAI · Codex"
        );
    }
    #[test]
    fn auto_follows_the_active_model_then_falls_back_to_the_latest_turn() {
        let now = Utc::now();
        let started = now - chrono::Duration::hours(1);
        let live = live_at(
            started,
            vec![
                response("a", now, "claude-opus-4", "claude-code", 80),
                response("b", now, "gpt-5", "codex", 30),
            ],
            now,
        );
        let turns = [turn("t", "codex", "gpt-5", now)];
        assert_eq!(
            state("auto", &live, Some(&key("claude-opus-4")), &turns, now).title,
            "CC 80.0 tok/s"
        );
        assert_eq!(
            state("auto", &live, None, &turns, now).title,
            "CX 30.0 tok/s"
        );
        // Auto within a tool restricts the scope to that tool: Claude Code has no live gpt-5
        // response, so its latest turn answers.
        let tool = state(
            "auto:claude-code",
            &live,
            None,
            &[turn("c", "claude-code", "gpt-5", now)],
            now,
        );
        assert_eq!(tool.title, "CC 20.0 tok/s");
        assert!(tool.detail.contains("Turn speed of the latest turn"));
        // "All" behaves like Auto without a tool.
        assert_eq!(
            state("all", &live, Some(&key("claude-opus-4")), &turns, now).title,
            "CC 80.0 tok/s"
        );
        assert_eq!(
            state("all", &live, None, &turns, now).title,
            "CX 30.0 tok/s"
        );
    }
    #[test]
    fn pinned_model_and_cohort_ignore_the_active_model() {
        let now = Utc::now();
        let started = now - chrono::Duration::hours(1);
        let live = live_at(
            started,
            vec![
                response("a", now, "claude-opus-4", "claude-code", 80),
                response("b", now, "gpt-5", "codex", 30),
                response("c", now, "gpt-5", "claude-code", 90),
            ],
            now,
        );
        let active = key("claude-opus-4");
        let pinned = state("model:[\"gpt-5\",null]", &live, Some(&active), &[], now);
        // The median of 30 and 90, attributed to the tool of the newest of them.
        assert_eq!(pinned.title, "CC 60.0 tok/s");
        assert!(pinned.detail.ends_with("gpt-5 · OpenAI · Claude Code"));
        // A pinned cohort is the UI's nine-part identity: its tool, model and provider.
        let cohort = serde_json::json!([
            "codex",
            null,
            "codex-rollout-v2",
            "turn-v1",
            "gpt-5",
            null,
            null,
            "high",
            "primary"
        ])
        .to_string();
        let mut pinned_turn = turn("t", "codex", "gpt-5", now);
        pinned_turn.parser_version = "codex-rollout-v2".into();
        pinned_turn.metric_version = "turn-v1".into();
        pinned_turn.reasoning_effort = Some("high".into());
        pinned_turn.source_kind = Some("primary".into());
        let cohort_state = state(&cohort, &live, Some(&active), &[pinned_turn], now);
        assert_eq!(cohort_state.title, "CX 30.0 tok/s");
        assert_eq!(cohort_state.badge, ProviderBadge::OpenAi);
    }
    /// The tray reads like the hero: each case is a situation of the dashboard's hero
    /// (`buildDashboard` in `ui/model/dashboard.ts`) with the value it shows.
    #[test]
    fn the_tray_shows_what_the_hero_shows_for_live_latest_fallback_and_nothing() {
        let now = Utc::now();
        let started = now - chrono::Duration::hours(2);
        let minutes = |count: i64| now - chrono::Duration::minutes(count);
        let live = live_at(
            started,
            vec![
                response("l1", minutes(3), "claude-opus-4", "claude-code", 30),
                response("l2", minutes(2), "claude-opus-4", "claude-code", 50),
                response("l3", minutes(1), "claude-opus-4", "claude-code", 70),
            ],
            now,
        );
        let none = LiveResponses::new(started);
        let turns = [
            // Newest first, as the history keeps them.
            timed_turn(
                "g",
                "grok-build",
                "grok-4",
                Some("xai"),
                minutes(20),
                (1_200, 16.0),
            ),
            timed_turn(
                "c",
                "claude-code",
                "claude-opus-4",
                Some("anthropic"),
                minutes(30),
                (500, 5.0),
            ),
            turn("x", "codex", "gpt-5", minutes(40)),
        ];
        let claude = key("claude-opus-4");
        // (selection, filters, live, active) -> (title, measure).
        type Case<'a> = (
            &'a str,
            DashboardFilters,
            &'a LiveResponses,
            Option<&'a ModelKey>,
            &'a str,
            &'a str,
        );
        let cases: [Case; 9] = [
            // Live: the median of the live responses (30, 50, 70).
            (
                "auto",
                no_filters(),
                &live,
                Some(&claude),
                "CC 50.0 tok/s",
                "Response speed",
            ),
            // The live stream is not narrowed by the dashboard's filters, as in the hero.
            (
                "auto",
                filters(Some("codex"), None),
                &live,
                Some(&claude),
                "CC 50.0 tok/s",
                "Response speed",
            ),
            (
                "auto",
                filters(None, Some("openai")),
                &live,
                Some(&claude),
                "CC 50.0 tok/s",
                "Response speed",
            ),
            // Latest turn: the newest turn with response timing of the followed model.
            (
                "auto",
                no_filters(),
                &none,
                None,
                "GB 75.0 tok/s",
                "Response speed of the latest turn",
            ),
            // A filter narrows the turns the fallback picks from.
            (
                "auto",
                filters(Some("claude-code"), None),
                &none,
                None,
                "CC 100 tok/s",
                "Response speed of the latest turn",
            ),
            (
                "auto:claude-code",
                no_filters(),
                &none,
                None,
                "CC 100 tok/s",
                "Response speed of the latest turn",
            ),
            (
                "auto",
                filters(None, Some("anthropic")),
                &none,
                None,
                "CC 100 tok/s",
                "Response speed of the latest turn",
            ),
            // Turn fallback: no response timing in scope, so the whole-turn speed.
            (
                "auto",
                filters(Some("codex"), None),
                &none,
                None,
                "CX 20.0 tok/s",
                "Turn speed of the latest turn",
            ),
            // Nothing in scope.
            (
                "auto",
                filters(Some("claude-code"), Some("openai")),
                &none,
                None,
                "—",
                "",
            ),
        ];
        for (selection, filters, live, active, title, measure) in cases {
            let settings = Settings {
                selection: selection.into(),
                ..Settings::default()
            };
            let shown = state_with(settings, &filters, live, active, &turns, now);
            assert_eq!(shown.title, title, "{selection} {filters:?}");
            assert!(shown.detail.contains(measure), "{}", shown.detail);
        }
    }
    #[test]
    fn paused_monitoring_shows_a_dash_and_hidden_speed_keeps_the_plain_tray() {
        let now = Utc::now();
        let live = live_at(
            now - chrono::Duration::hours(1),
            vec![response("a", now, "gpt-5", "codex", 40)],
            now,
        );
        let paused = state_with(
            Settings {
                monitoring: false,
                ..Settings::default()
            },
            &no_filters(),
            &live,
            Some(&key("gpt-5")),
            &[],
            now,
        );
        assert_eq!(paused.title, "—");
        assert_eq!(
            paused.detail,
            "Tokrate · Response speed — · monitoring paused"
        );
        assert!(!paused.badge_model_known);
        let hidden = state_with(
            Settings {
                show_speed: false,
                ..Settings::default()
            },
            &no_filters(),
            &live,
            Some(&key("gpt-5")),
            &[],
            now,
        );
        assert_eq!(
            (hidden.title.as_str(), hidden.detail.as_str()),
            ("Tokrate", "Tokrate")
        );
        assert!(!hidden.badge_model_known);
    }
    #[test]
    fn tool_chip_defaults_on_loads_when_absent_and_is_patchable() {
        assert!(Settings::default().show_tool_chip);
        let dir = temporary();
        let mut settings = saved_settings(false, None);
        settings.as_object_mut().unwrap().remove("showToolChip");
        write_settings(&dir, settings);
        let mut runtime = Runtime::load(dir.clone()).unwrap();
        assert!(runtime.settings.show_tool_chip);
        let patch = serde_json::from_value(serde_json::json!({"showToolChip": false})).unwrap();
        runtime.update(patch).unwrap();
        assert!(!runtime.settings.show_tool_chip);
        let saved: serde_json::Value =
            serde_json::from_slice(&std::fs::read(dir.join("settings.json")).unwrap()).unwrap();
        assert_eq!(saved["showToolChip"], false);
        assert!(!Runtime::load(dir.clone()).unwrap().settings.show_tool_chip);
        std::fs::remove_dir_all(dir).unwrap();
    }
    #[test]
    fn dashboard_filters_are_validated_and_ask_for_a_poll_only_when_they_change() {
        let dir = temporary();
        let mut runtime = Runtime::load(dir.clone()).unwrap();
        assert_eq!(runtime.filters, no_filters());
        runtime
            .set_dashboard_filters("claude-code", "anthropic")
            .unwrap();
        assert_eq!(
            runtime.filters,
            filters(Some("claude-code"), Some("anthropic"))
        );
        assert!(runtime.signal.take().requested);
        runtime
            .set_dashboard_filters("claude-code", "anthropic")
            .unwrap();
        assert!(!runtime.signal.take().requested);
        runtime.set_dashboard_filters("all", "all").unwrap();
        assert_eq!(runtime.filters, no_filters());
        for (tool, provider) in [("vim", "all"), ("all", "mystery"), ("", "all")] {
            assert!(runtime.set_dashboard_filters(tool, provider).is_err());
        }
        assert_eq!(runtime.filters, no_filters());
        std::fs::remove_dir_all(dir).unwrap();
    }
    #[test]
    fn the_tray_follows_the_filters_the_flyout_reported() {
        let dir = temporary();
        let mut runtime = Runtime::load(dir.clone()).unwrap();
        let now = Utc::now();
        let minutes = |count: i64| now - chrono::Duration::minutes(count);
        runtime.history.merge(
            &[
                timed_turn(
                    "a",
                    "codex",
                    "gpt-5",
                    Some("openai"),
                    minutes(5),
                    (900, 12.0),
                ),
                timed_turn(
                    "b",
                    "claude-code",
                    "claude-opus-4",
                    Some("anthropic"),
                    minutes(10),
                    (500, 5.0),
                ),
            ],
            now,
        );
        assert_eq!(runtime.tray_state(now).title, "CX 75.0 tok/s");
        runtime.set_dashboard_filters("claude-code", "all").unwrap();
        assert_eq!(runtime.tray_state(now).title, "CC 100 tok/s");
        std::fs::remove_dir_all(dir).unwrap();
    }
    #[test]
    fn snapshot_exposes_live_responses_and_the_active_model_without_touching_the_revision() {
        let dir = temporary();
        let mut runtime = Runtime::load(dir.clone()).unwrap();
        let now = Utc::now();
        assert!(runtime
            .live
            .push(vec![response("a", now, "gpt-5", "codex", 40)], now));
        runtime.active = Some(key("gpt-5"));
        let snapshot = runtime.snapshot(None);
        assert_eq!(snapshot.revision, 0);
        let json = serde_json::to_value(&snapshot).unwrap();
        assert_eq!(json["live"][0]["id"], "a");
        assert_eq!(json["active"]["model"], "gpt-5");
        std::fs::remove_dir_all(dir).unwrap();
    }
    #[test]
    fn records_are_sent_again_only_when_the_history_changed() {
        let dir = temporary();
        let mut runtime = Runtime::load(dir.clone()).unwrap();
        let now = Utc::now();
        runtime.ingest(vec![turn("t1", "codex", "gpt-5", now)], false, now);
        assert_eq!(runtime.revision, 1);
        let first = runtime.snapshot(None);
        assert!(first.records_changed);
        assert_eq!(first.records.len(), 1);
        // New live data and an idle poll move the live fields, not the revision.
        assert!(runtime
            .live
            .push(vec![response("a", now, "gpt-5", "codex", 40)], now));
        runtime.ingest(Vec::new(), false, now + chrono::Duration::seconds(30));
        let polled = runtime.snapshot(Some(first.revision));
        assert!(!polled.records_changed);
        assert!(polled.records.is_empty());
        assert_eq!(polled.live.len(), 1);
        assert_eq!(runtime.revision, 1);
        // A different revision gets the records.
        assert_eq!(runtime.snapshot(Some(0)).records.len(), 1);
        std::fs::remove_dir_all(dir).unwrap();
    }

    /// Deletes `history.json` and says whether it was there: a save happened since the last look.
    fn history_was_saved(dir: &std::path::Path) -> bool {
        std::fs::remove_file(dir.join("history.json")).is_ok()
    }
    #[test]
    fn history_is_saved_at_most_every_ten_seconds_while_records_keep_arriving() {
        let dir = temporary();
        let mut runtime = Runtime::load(dir.clone()).unwrap();
        let base = Utc::now();
        let mut saves = Vec::new();
        for step in 0..30 {
            let now = base + chrono::Duration::seconds(2 * step);
            let found = vec![turn(&format!("t{step}"), "codex", "gpt-5", now)];
            let polled = runtime.ingest(found, false, now);
            if history_was_saved(&dir) {
                saves.push(2 * step);
            }
            // Every poll with new records is a revision for the webview, saved or not.
            assert_eq!(runtime.revision, step as u64 + 1);
            // The unsaved remainder is written when its interval ends, not at the idle cadence.
            if runtime.history_unsaved {
                let last = *saves.last().unwrap();
                assert!(polled.deadline.unwrap() <= base + chrono::Duration::seconds(last + 10));
            } else {
                assert_eq!(polled.deadline, None);
            }
        }
        // The first record is written at once; then one write per ten seconds, never closer.
        assert_eq!(saves, [0, 10, 20, 30, 40, 50]);
        // The records after the last write are written by the next poll once the interval is over,
        // and with nothing new nothing is written again.
        let quiet = base + chrono::Duration::seconds(300);
        runtime.ingest(Vec::new(), false, quiet);
        assert!(history_was_saved(&dir));
        runtime.ingest(Vec::new(), false, quiet + chrono::Duration::seconds(30));
        assert!(!history_was_saved(&dir));
        // Unsaved records are written on exit, and only then.
        runtime.ingest(vec![turn("last", "codex", "gpt-5", quiet)], false, quiet);
        assert!(!history_was_saved(&dir));
        runtime.save_on_exit();
        assert!(history_was_saved(&dir));
        runtime.save_on_exit();
        assert!(!history_was_saved(&dir));
        std::fs::remove_dir_all(dir).unwrap();
    }
    #[test]
    fn retention_pruning_runs_only_when_something_expired_and_at_most_every_ten_minutes() {
        let dir = temporary();
        let mut runtime = Runtime::load(dir.clone()).unwrap();
        let now = Utc::now();
        let old = now - chrono::Duration::days(6);
        runtime.ingest(
            vec![turn("old", "codex", "gpt-5", old)],
            false,
            old + chrono::Duration::days(6),
        );
        assert_eq!(runtime.history.records().len(), 1);
        let revision = runtime.revision;
        // Idle polls change nothing while the oldest turn is inside the window.
        for minutes in [1, 61, 600] {
            runtime.ingest(Vec::new(), false, now + chrono::Duration::minutes(minutes));
        }
        assert_eq!(runtime.revision, revision);
        assert_eq!(runtime.history.records().len(), 1);
        // Once it has expired the next poll removes it, with a revision for the webview.
        history_was_saved(&dir);
        let later = now + chrono::Duration::days(2);
        runtime.ingest(Vec::new(), false, later);
        assert!(runtime.history.records().is_empty());
        assert_eq!(runtime.revision, revision + 1);
        assert!(history_was_saved(&dir));
        std::fs::remove_dir_all(dir).unwrap();
    }
    #[test]
    fn a_failed_poll_is_retried_at_the_minimum_spacing() {
        let dir = temporary();
        let mut runtime = Runtime::load(dir.clone()).unwrap();
        let now = Utc::now();
        let polled = runtime.ingest(Vec::new(), true, now);
        assert_eq!(polled.deadline, Some(now));
        assert_eq!(
            schedule::poll_delay(now, now, polled.deadline),
            schedule::MIN_POLL_SPACING
        );
        let idle = runtime.ingest(Vec::new(), false, now);
        assert_eq!(idle.deadline, None);
        std::fs::remove_dir_all(dir).unwrap();
    }
    #[test]
    fn only_changes_the_monitors_care_about_make_a_poll_due() {
        let dir = temporary();
        let mut runtime = Runtime::load_smoke(dir.clone()).unwrap();
        let codex = PathBuf::from(&runtime.settings.root);
        // A poll runs discovery once; after it an idle monitor has nothing pending.
        runtime.poll_monitor_at(Utc::now());
        assert!(!runtime.absorb_signal());
        let rollout = codex.join("rollout.jsonl");
        std::fs::write(&rollout, b"{}\n").unwrap();
        let change = |paths: &[&std::path::Path], must_rescan| tokrate_core::SourceChange {
            paths: paths.iter().map(|path| path.to_path_buf()).collect(),
            must_rescan,
        };
        runtime.signal.report(change(&[&rollout], false));
        assert!(runtime.absorb_signal(), "a new session file needs a poll");
        runtime.poll_monitor_at(Utc::now());
        assert!(!runtime.absorb_signal());
        // A file the monitors do not read, and a path outside every root, do not.
        let noise = codex.join("notes.txt");
        std::fs::write(&noise, b"x").unwrap();
        runtime
            .signal
            .report(change(&[&noise, &dir.join("elsewhere.jsonl")], false));
        assert!(!runtime.absorb_signal());
        // Lost events and a settings change do.
        runtime.signal.report(change(&[], true));
        assert!(runtime.absorb_signal());
        runtime.poll_monitor_at(Utc::now());
        runtime
            .update(serde_json::from_value(serde_json::json!({"showSpeed": false})).unwrap())
            .unwrap();
        assert!(runtime.absorb_signal());
        // While monitoring is paused a change waits for it instead of waking the poll.
        runtime
            .update(serde_json::from_value(serde_json::json!({"monitoring": false})).unwrap())
            .unwrap();
        runtime.absorb_signal();
        runtime.signal.report(change(&[], true));
        assert!(!runtime.absorb_signal());
        std::fs::remove_dir_all(dir).unwrap();
    }
    #[test]
    fn a_database_change_wakes_a_poll_for_antigravity_and_opencode_but_their_other_files_do_not() {
        let dir = temporary();
        let mut runtime = Runtime::load_smoke(dir.clone()).unwrap();
        let change = |paths: &[&std::path::Path]| tokrate_core::SourceChange {
            paths: paths.iter().map(|path| path.to_path_buf()).collect(),
            must_rescan: false,
        };
        let opencode = PathBuf::from(&runtime.settings.opencode_root);
        let gemini = PathBuf::from(&runtime.settings.antigravity_root);
        let conversations = gemini.join("antigravity/conversations");
        std::fs::create_dir_all(&conversations).unwrap();
        runtime.poll_monitor_at(Utc::now());
        assert!(!runtime.absorb_signal());
        // Logs, snapshots and caches next to the databases change constantly and wake nothing.
        let noise = [
            opencode.join("log/today.log"),
            opencode.join("opencode.db-shm"),
            gemini.join("antigravity-browser-profile/Cookies"),
            conversations.join("old.pb"),
            conversations.join("a.db-shm"),
        ];
        let noise: Vec<&std::path::Path> = noise.iter().map(PathBuf::as_path).collect();
        runtime.signal.report(change(&noise));
        assert!(!runtime.absorb_signal());
        assert!(runtime.monitor.next_poll_deadline(Utc::now()).is_none());
        // The databases do: OpenCode's directly, Antigravity's as a new conversation.
        let opencode_db = opencode.join("opencode.db");
        std::fs::write(&opencode_db, b"not a database").unwrap();
        runtime.signal.report(change(&[&opencode_db]));
        assert!(runtime.absorb_signal());
        assert!(runtime.monitor.next_poll_deadline(Utc::now()).is_some());
        runtime.poll_monitor_at(Utc::now());
        let conversation = conversations.join("a.db");
        std::fs::write(&conversation, b"not a database").unwrap();
        runtime.signal.report(change(&[&conversation]));
        assert!(runtime.absorb_signal());
        std::fs::remove_dir_all(dir).unwrap();
    }
    #[test]
    fn the_watch_targets_follow_the_monitor_roots() {
        let dir = temporary();
        let mut runtime = Runtime::load_smoke(dir.clone()).unwrap();
        let targets = runtime.watch_targets();
        let sources: Vec<_> = targets.iter().map(|target| target.source).collect();
        assert_eq!(
            sources,
            [
                "codex",
                "claude-code",
                "grok-build",
                "antigravity",
                "antigravity-ide",
                "antigravity-cli",
                "opencode"
            ]
        );
        // The smoke roots exist, but not Antigravity's conversation folders below its root.
        let exists: Vec<_> = targets.iter().map(|target| target.exists).collect();
        assert_eq!(exists, [true, true, true, false, false, false, true]);
        // Antigravity's folders and OpenCode's data folder are watched shallowly.
        let recursive: Vec<_> = targets.iter().map(|target| target.recursive).collect();
        assert_eq!(recursive, [true, true, true, false, false, false, false]);
        assert_eq!(
            targets[3].root,
            PathBuf::from(&runtime.settings.antigravity_root).join("antigravity/conversations")
        );
        assert_eq!(
            targets[6].root,
            PathBuf::from(&runtime.settings.opencode_root)
        );
        let custom = dir.join("custom-codex");
        std::fs::create_dir_all(&custom).unwrap();
        runtime.set_source_root("codex", custom.clone()).unwrap();
        assert_eq!(runtime.watch_targets()[0].root, custom);
        std::fs::remove_dir_all(&custom).unwrap();
        assert!(!runtime.watch_targets()[0].exists);
        std::fs::remove_dir_all(dir).unwrap();
    }

    /// A Codex rollout of `count` quick turns, the last one finished `end_minutes_ago` minutes ago.
    fn write_rollout(path: &std::path::Path, count: i64, end_minutes_ago: i64) {
        let end = Utc::now() - chrono::Duration::minutes(end_minutes_ago);
        let stamp = |at: DateTime<Utc>| at.to_rfc3339_opts(chrono::SecondsFormat::Secs, true);
        let mut lines = vec![serde_json::json!({
            "type": "session_meta",
            "payload": {"id": "fixture-session", "cli_version": "0.159.2", "source": "cli", "model_provider": "openai"}
        })];
        for index in 0..count {
            let finished = end - chrono::Duration::seconds(3 * (count - 1 - index));
            let turn = format!("turn-{index}");
            lines.push(serde_json::json!({
                "type": "event_msg", "timestamp": stamp(finished - chrono::Duration::seconds(2)),
                "payload": {"type": "task_started", "turn_id": turn}
            }));
            lines.push(serde_json::json!({
                "type": "turn_context",
                "payload": {"turn_id": turn, "model": "fixture-model", "effort": "high"}
            }));
            lines.push(serde_json::json!({
                "type": "token_usage_record",
                "payload": {"turn_id": turn, "turn_token_usage": {"output_tokens": 200}}
            }));
            lines.push(serde_json::json!({
                "type": "event_msg", "timestamp": stamp(finished),
                "payload": {"type": "task_complete", "turn_id": turn, "duration_ms": 2000, "time_to_first_token_ms": 500}
            }));
        }
        let text: String = lines.iter().map(|line| line.to_string() + "\n").collect();
        std::fs::write(path, text).unwrap();
    }
    fn saved_codex_checkpoints(dir: &std::path::Path) -> usize {
        let saved: serde_json::Value =
            serde_json::from_slice(&std::fs::read(dir.join("history.json")).unwrap()).unwrap();
        saved["checkpoints"]["codex"].as_array().map_or(0, Vec::len)
    }
    #[test]
    fn a_replay_is_saved_when_it_ends_and_the_next_launch_skips_what_it_covered() {
        let dir = temporary();
        let mut runtime = Runtime::load_smoke(dir.clone()).unwrap();
        let rollout = std::path::Path::new(&runtime.settings.root).join("rollout.jsonl");
        write_rollout(&rollout, 700, 30);
        // Quiet for long enough that a later launch applies the checkpoint.
        std::fs::File::options()
            .write(true)
            .open(&rollout)
            .unwrap()
            .set_modified(std::time::SystemTime::now() - Duration::from_secs(20 * 60))
            .unwrap();
        let base = Utc::now();
        let mut polls = 0;
        let mut saves = 0;
        loop {
            let now = base + chrono::Duration::seconds(2 * polls);
            runtime.poll_monitor_at(now);
            saves += history_was_saved_keeping(&dir) as usize;
            polls += 1;
            assert!(polls < 60, "the replay never ended");
            if !runtime.was_busy {
                break;
            }
        }
        assert!(
            polls > 3,
            "the fixture was read in {polls} polls: no replay to speak of"
        );
        // At most one write per ten seconds during the replay, and one when it ended.
        assert!(
            saves >= 1 && saves as i64 <= 2 * polls / 10 + 2,
            "{saves} saves in {polls} polls"
        );
        assert_eq!(
            saved_codex_checkpoints(&dir),
            1,
            "the replay's end was not saved"
        );
        let records = runtime.history.records().len();
        assert_eq!(records, 700);
        drop(runtime);

        // A new launch hands the saved checkpoints to the monitors and reads nothing again.
        let mut restarted = Runtime::load_smoke(dir.clone()).unwrap();
        assert_eq!(restarted.history.records().len(), records);
        assert_eq!(restarted.history.checkpoints().codex.len(), 1);
        let polled = restarted.poll_monitor_at(Utc::now());
        assert_eq!(restarted.monitor.bytes_read_last_poll(), 0);
        assert!(!restarted.was_busy);
        assert_eq!(restarted.history.records().len(), records);
        assert_eq!(polled.deadline, None);
        std::fs::remove_dir_all(dir).unwrap();
    }
    /// Whether history.json was written since the last look, without removing it.
    fn history_was_saved_keeping(dir: &std::path::Path) -> bool {
        thread_local!(static LAST: std::cell::Cell<Option<std::time::SystemTime>> = const { std::cell::Cell::new(None) });
        let modified = std::fs::metadata(dir.join("history.json"))
            .and_then(|meta| meta.modified())
            .ok();
        LAST.with(|last| {
            let changed = modified.is_some() && modified != last.get();
            last.set(modified);
            changed
        })
    }
    #[test]
    fn grok_turns_completed_after_launch_become_live_responses() {
        let dir = temporary();
        let mut runtime = Runtime::load_smoke(dir.clone()).unwrap();
        let launched = Utc::now();
        let session = std::path::Path::new(&runtime.settings.grok_root).join("grok-session");
        std::fs::create_dir_all(&session).unwrap();
        let stamp = |seconds: i64| {
            (launched + chrono::Duration::seconds(seconds))
                .to_rfc3339_opts(chrono::SecondsFormat::Millis, true)
        };
        let events: Vec<serde_json::Value> = vec![
            serde_json::json!({"type": "turn_started", "schema_version": "1.0", "ts": stamp(1), "session_id": "grok-session", "turn_number": 0, "model_id": "grok-4", "session_relationship": "primary"}),
            serde_json::json!({"type": "loop_started", "ts": stamp(2), "loop_index": 0}),
            serde_json::json!({"type": "turn_ended", "ts": stamp(22), "outcome": "completed"}),
        ];
        std::fs::write(
            session.join("events.jsonl"),
            events
                .iter()
                .map(|event| event.to_string() + "\n")
                .collect::<String>(),
        )
        .unwrap();
        std::fs::write(
            session.join("usage.json"),
            serde_json::json!({
                "sessionId": "grok-session",
                "updatedAt": stamp(22),
                "session": {},
                "turns": [{
                    "turnNumber": 1, "endedAt": stamp(22), "outputTokens": 1500, "reasoningTokens": 10,
                    "modelCalls": 1, "usageIsIncomplete": false, "primaryModelId": "grok-4",
                    "modelUsage": {"grok-4": {"outputTokens": 1500}}
                }]
            })
            .to_string(),
        )
        .unwrap();
        let now = launched + chrono::Duration::seconds(60);
        let polled = runtime.poll_monitor_at(now);
        let live = runtime.live.responses();
        assert_eq!(live.len(), 1, "{:?}", runtime.history.records());
        assert_eq!(live[0].client, "grok-build");
        // 1,500 tokens over the 20 s the model call took.
        assert_eq!(live[0].speed(), 75.0);
        // The tray (and the flyout's hero) read it as a live value, with the tool's chip.
        assert_eq!(polled.tray.title, "GB 75.0 tok/s");
        assert_eq!(
            runtime.active.as_ref().and_then(|key| key.model.as_deref()),
            Some("grok-4")
        );
        // Polling again does not count the turn twice.
        runtime.poll_monitor_at(now + chrono::Duration::seconds(2));
        assert_eq!(runtime.live.len(), 1);
        std::fs::remove_dir_all(dir).unwrap();
    }
}
