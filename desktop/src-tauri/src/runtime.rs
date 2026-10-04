use crate::Shared;
use chrono::Utc;
use futures_util::StreamExt;
use rand::RngCore;
use serde::{Deserialize, Serialize};
use std::{
    path::PathBuf,
    sync::{Arc, Mutex},
    time::Duration,
};
use tauri::Manager;
use tokrate_core::{signed_request, History, SharingQueue, SourceMonitor, TurnMetric};
use zeroize::Zeroizing;
const API: &str = "https://tokrate.dev/api/public/v1";
pub const SHARING_NOTICE_VERSION: &str = "2026-10-04-v1";

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
    pub days: u8,
    pub root: String,
    pub claude_root: String,
    pub grok_root: String,
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
        Self {
            sharing: false,
            sharing_consent: None,
            monitoring: true,
            show_speed: true,
            selection: "latest".into(),
            days: 1,
            root: codex_home.join("sessions").to_string_lossy().into(),
            claude_root: claude_home.join("projects").to_string_lossy().into(),
            grok_root: grok_home.join("sessions").to_string_lossy().into(),
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
    pub days: Option<u8>,
}
#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Snapshot {
    settings: Settings,
    consent_prompt_required: bool,
    records: Vec<TurnMetric>,
    status: String,
    monitor_status: String,
    pending: usize,
    board: Option<serde_json::Value>,
    revision: u64,
    records_changed: bool,
    smoke: bool,
}
pub struct Runtime {
    settings: Settings,
    consent_prompt_required: bool,
    history: History,
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
    last_history_maintenance: std::time::Instant,
}
impl Runtime {
    pub fn load(dir: PathBuf) -> Result<Self, Box<dyn std::error::Error>> {
        std::fs::create_dir_all(&dir)?;
        let (settings, status, consent_prompt_required) =
            match std::fs::read(dir.join("settings.json")) {
                Ok(bytes) => match serde_json::from_slice::<Settings>(&bytes) {
                    Ok(mut s) if [1, 7].contains(&s.days) => {
                        if !valid_selection(&s.selection) {
                            s.selection = "latest".into();
                        }
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
        Ok(Self {
            monitor: SourceMonitor::new(
                PathBuf::from(&settings.root),
                PathBuf::from(&settings.claude_root),
                PathBuf::from(&settings.grok_root),
            ),
            settings,
            consent_prompt_required,
            history,
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
            last_history_maintenance: std::time::Instant::now(),
        })
    }
    pub fn load_smoke(dir: PathBuf) -> Result<Self, Box<dyn std::error::Error>> {
        std::fs::create_dir_all(&dir)?;
        let mut settings = Settings::default();
        settings.sharing = false;
        settings.root = dir.join("sessions").to_string_lossy().into();
        settings.claude_root = dir.join("claude-projects").to_string_lossy().into();
        settings.grok_root = dir.join("grok-sessions").to_string_lossy().into();
        for root in [&settings.root, &settings.claude_root, &settings.grok_root] {
            std::fs::create_dir_all(root)?;
        }
        std::fs::write(dir.join("settings.json"), serde_json::to_vec(&settings)?)?;
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
        std::fs::write(
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
            status: self.status.clone(),
            monitor_status: self.monitor_status.clone(),
            pending: self.queue.len(),
            board: self.board.clone(),
            revision: self.revision,
            records_changed: changed,
            smoke: self.smoke,
        }
    }
    fn save_settings(&self, settings: &Settings) -> Result<(), String> {
        let bytes = serde_json::to_vec_pretty(settings).map_err(|_| "Settings invalid")?;
        std::fs::write(self.dir.join("settings.json"), bytes)
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
            next.selection = v
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
        let mut next = self.settings.clone();
        match source {
            "codex" => next.root = root.to_string_lossy().into(),
            "claude-code" => next.claude_root = root.to_string_lossy().into(),
            "grok-build" => next.grok_root = root.to_string_lossy().into(),
            _ => return Err("Choose a supported source".into()),
        }
        self.save_settings(&next)?;
        self.settings = next;
        self.monitor
            .set_root(source, root)
            .map_err(|_| "Could not start the selected monitor")?;
        Ok(())
    }
    fn valid(&self, g: u64) -> bool {
        self.settings.sharing_authorized() && self.generation == g
    }
    fn poll_monitor(&mut self) -> String {
        let now = Utc::now();
        let mut records = Vec::new();
        if self.settings.monitoring {
            match self.monitor.poll(now) {
                Ok(found) => {
                    records = found;
                    if self.monitor.had_source_error() {
                        self.monitor_status = "A source folder could not be read. Other available monitors remain active.".into();
                    } else {
                        self.monitor_status = self.source_status();
                    }
                }
                Err(_) => {
                    self.monitor_status =
                        "A selected source folder is unavailable. Choose an existing sessions or projects folder."
                            .into()
                }
            }
        } else {
            self.monitor_status = "Monitoring paused".into();
        }
        let new_records = !records.is_empty();
        if self.sharing_active {
            self.queue.enqueue(&records, now);
        }
        if new_records || self.last_history_maintenance.elapsed() >= Duration::from_secs(60) {
            let previous_count = self.history.records().len();
            self.history.merge(&records, now);
            self.last_history_maintenance = std::time::Instant::now();
            if new_records || previous_count != self.history.records().len() {
                self.revision += 1;
                if !self.history_read_error
                    && self.history.save(self.dir.join("history.json")).is_err()
                {
                    self.monitor_status = "Could not save local history. Check disk access.".into();
                }
            }
        }
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
            let _ = std::fs::write(self.dir.join("smoke-state.json"), evidence.to_string());
        }
        self.tray_text()
    }
    fn tray_text(&self) -> String {
        if !self.settings.monitoring || !self.settings.show_speed {
            return "Tokrate".into();
        }
        let records = self.history.records();
        let selected = if self.settings.selection == "latest" {
            records.first().map(cohort)
        } else {
            Some(self.settings.selection.clone())
        };
        let value = records.iter().find(|m| {
            m.completed_at >= Utc::now() - chrono::Duration::minutes(15)
                && m.output_tokens >= 20
                && Some(cohort(m)) == selected
        });
        value
            .map(|m| format!("{:.1} t/s · {}", m.turn_throughput_tps, metric_label(m)))
            .unwrap_or_else(|| "Tokrate · no selected turn".into())
    }

    fn source_status(&self) -> String {
        let mut sources = Vec::new();
        for (name, root) in [
            ("Codex", &self.settings.root),
            ("Claude Code", &self.settings.claude_root),
            ("Grok Build", &self.settings.grok_root),
        ] {
            if PathBuf::from(root).is_dir() {
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
fn cohort(m: &TurnMetric) -> String {
    serde_json::json!([
        m.client,
        m.client_version,
        m.parser_version,
        m.metric_version,
        m.model,
        m.provider,
        m.reasoning_effort,
        m.source_kind
    ])
    .to_string()
}
fn valid_selection(value: &str) -> bool {
    if matches!(value, "latest" | "all") {
        return true;
    }
    serde_json::from_str::<Vec<serde_json::Value>>(value).is_ok_and(|parts| parts.len() == 8)
}
fn metric_label(metric: &TurnMetric) -> &'static str {
    match metric.client.as_str() {
        "claude-code" if metric.metric_version == "claude-observed-subagent-turn-v1" => {
            "subagent turn speed"
        }
        "claude-code" => "transcript-observed turn throughput",
        "grok-build" => "work-turn throughput · includes nested agent output",
        _ => "completed-turn throughput",
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
    tauri::async_runtime::spawn(async move {
        loop {
            let shared = app.state::<Shared>().inner().clone();
            let result =
                tauri::async_runtime::spawn_blocking(move || shared.lock().unwrap().poll_monitor())
                    .await;
            if let Ok(text) = result {
                let _ = speed.set_text(&text);
                if let Some(tray) = app.tray_by_id("tokrate") {
                    let _ = tray.set_tooltip(Some(&text));
                    #[cfg(not(target_os = "windows"))]
                    {
                        let _ = tray.set_title(Some(&text));
                    }
                }
            }
            tokio::time::sleep(Duration::from_secs(2)).await;
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
    let client = match reqwest::Client::builder()
        .https_only(true)
        .redirect(reqwest::redirect::Policy::none())
        .timeout(Duration::from_secs(20))
        .build()
    {
        Ok(c) => c,
        Err(_) => return,
    };
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
        tokio::time::sleep(Duration::from_secs(30)).await;
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
    fn smoke_mode_uses_only_temporary_source_roots_and_stays_local() {
        let dir = temporary();
        let runtime = Runtime::load_smoke(dir.clone()).unwrap();
        let roots = [
            PathBuf::from(&runtime.settings.root),
            PathBuf::from(&runtime.settings.claude_root),
            PathBuf::from(&runtime.settings.grok_root),
        ];
        assert_eq!(
            roots,
            [
                dir.join("sessions"),
                dir.join("claude-projects"),
                dir.join("grok-sessions")
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
    #[test]
    fn tray_never_presents_an_old_turn_as_current() {
        let dir = temporary();
        let mut runtime = Runtime::load_smoke(dir.clone()).unwrap();
        let now = Utc::now();
        let metric = TurnMetric::new(
            "fixture".into(),
            now - chrono::Duration::minutes(16),
            Some("fixture-model".into()),
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
        runtime.history.merge(&[metric.clone()], now);
        assert_eq!(runtime.tray_text(), "Tokrate · no selected turn");
        let mut fresh = metric;
        fresh.id = "fresh".into();
        fresh.completed_at = now;
        runtime.history.merge(&[fresh], now);
        assert_eq!(runtime.tray_text(), "20.0 t/s · completed-turn throughput");
        std::fs::remove_dir_all(dir).unwrap();
    }
}
