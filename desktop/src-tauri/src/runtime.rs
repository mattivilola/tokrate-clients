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
use tokrate_core::{signed_request, History, Monitor, SharingQueue, TurnMetric};
use zeroize::Zeroizing;
const API: &str = "https://tokrate.dev/api/public/v1";
#[derive(Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Settings {
    pub sharing: bool,
    pub monitoring: bool,
    pub show_speed: bool,
    pub selection: String,
    pub days: u8,
    pub root: String,
}
impl Default for Settings {
    fn default() -> Self {
        let root = std::env::var_os("CODEX_HOME")
            .map(PathBuf::from)
            .unwrap_or_else(|| {
                let home = std::env::var_os(if cfg!(windows) { "USERPROFILE" } else { "HOME" })
                    .unwrap_or_default();
                PathBuf::from(home).join(".codex")
            })
            .join("sessions");
        Self {
            sharing: true,
            monitoring: true,
            show_speed: true,
            selection: "latest".into(),
            days: 1,
            root: root.to_string_lossy().into(),
        }
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
    history: History,
    monitor: Monitor,
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
        let (settings, status) = match std::fs::read(dir.join("settings.json")) {
            Ok(bytes) => match serde_json::from_slice::<Settings>(&bytes) {
                Ok(s) if [1, 7].contains(&s.days) => (s, "Starting…"),
                _ => {
                    let mut s = Settings::default();
                    s.sharing = false;
                    (
                        s,
                        "Settings could not be read. Sharing is off; review your settings.",
                    )
                }
            },
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => {
                (Settings::default(), "Starting…")
            }
            Err(_) => {
                let mut s = Settings::default();
                s.sharing = false;
                (s, "Settings unavailable. Sharing is off.")
            }
        };
        let loaded_history = History::load(&dir.join("history.json"), Utc::now());
        let history_read_error = loaded_history.is_err();
        let history = loaded_history.unwrap_or_default();
        Ok(Self {
            monitor: Monitor::new(PathBuf::from(&settings.root)),
            settings,
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
            || self.history.records().is_empty()
        {
            return Err("Smoke state invalid".into());
        }
        std::fs::write(
            self.dir.join("smoke-result.json"),
            b"{\"nativeWebview\":true,\"parsedFixture\":true,\"sharingOff\":true}",
        )
        .map_err(|_| "Cannot write smoke result".into())
    }
    pub fn snapshot(&self, since: Option<u64>) -> Snapshot {
        let changed = since != Some(self.revision);
        Snapshot {
            settings: self.settings.clone(),
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
            if self.smoke && v {
                return Err("Smoke runs cannot share".into());
            }
            next.sharing = v
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
        Ok(())
    }
    pub fn set_root(&mut self, root: PathBuf) -> Result<(), String> {
        if !root.is_dir() {
            return Err("Choose an existing folder".into());
        }
        let mut next = self.settings.clone();
        next.root = root.to_string_lossy().into();
        self.save_settings(&next)?;
        self.settings = next;
        self.monitor = Monitor::new(root);
        Ok(())
    }
    fn valid(&self, g: u64) -> bool {
        self.settings.sharing && self.generation == g
    }
    fn poll_monitor(&mut self) -> String {
        let now = Utc::now();
        let mut records = Vec::new();
        if self.settings.monitoring {
            match self.monitor.poll(now) {
                Ok(found) => {
                    records = found;
                    self.monitor_status = "Monitoring Codex sessions".into();
                }
                Err(_) => {
                    self.monitor_status =
                        "Session folder unavailable. Start Codex or choose its sessions folder."
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
            let evidence = serde_json::json!({"records": self.history.records().len(), "sharing": self.settings.sharing, "monitorStatus": self.monitor_status});
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
            .map(|m| format!("{:.1} t/s · completed turn", m.turn_throughput_tps))
            .unwrap_or_else(|| "Tokrate · no selected turn".into())
    }
}
fn cohort(m: &TurnMetric) -> String {
    serde_json::json!([m.model, m.provider, m.client_version, m.reasoning_effort]).to_string()
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
    if !s.settings.sharing {
        s.status = "Local only".into();
        return;
    }
    let generation = s.generation;
    s.status = "Opening secure credential storage…".into();
    let inner = shared.clone();
    s.network = Some(tauri::async_runtime::spawn(async move {
        sharing_loop(inner, generation).await
    }));
}
async fn sharing_loop(shared: Arc<Mutex<Runtime>>, generation: u64) {
    let key = match tauri::async_runtime::spawn_blocking(identity).await {
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
                if !shared.lock().unwrap().valid(generation) {
                    return;
                }
                let result = client
                    .post(format!("{API}/samples"))
                    .header("Content-Type", "application/json")
                    .header("X-Tokrate-Key", request.public_key)
                    .header("X-Tokrate-Signature", request.signature)
                    .body(request.body)
                    .send()
                    .await;
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
                    Ok(r) if [400, 413, 422].contains(&r.status().as_u16()) => {
                        s.queue
                            .ack(&batch.iter().map(|m| m.sample_id).collect::<Vec<_>>());
                        s.status = "Some reports were rejected. Local history is safe.".into()
                    }
                    _ => s.status = "Upload unavailable. Retrying while sharing is on.".into(),
                }
            }
        }
        if !shared.lock().unwrap().valid(generation) {
            return;
        }
        let board = fetch_board(&client).await;
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
        assert!(!runtime.settings.sharing);
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
        assert_eq!(runtime.tray_text(), "20.0 t/s · completed turn");
        std::fs::remove_dir_all(dir).unwrap();
    }
}
