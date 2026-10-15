use crate::{
    config::{Paths, Result, Settings},
    credentials,
    schedule::PollSignal,
    watcher::{WatchTarget, Watchers},
};
use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use std::{
    sync::Arc,
    time::{Duration, Instant},
};
use tokrate_core::{
    signed_request, tray_reading, write_private_file, AutoSelector, History, LiveResponses,
    ResponseMetric, SelectionMode, SharingQueue, SourceMonitor, TrayReadingKind, UploadBatch,
    APP_VERSION,
};
use zeroize::Zeroizing;

const API: &str = "https://tokrate.dev/api/public/v1/samples";

#[derive(Default, Deserialize, Serialize)]
pub struct Status {
    pub version: String,
    pub started_at: Option<DateTime<Utc>>,
    pub updated_at: Option<DateTime<Utc>>,
    pub monitoring: bool,
    pub sharing_requested: bool,
    pub sharing_active: bool,
    pub history_turns: usize,
    pub pending_samples: usize,
    pub pending_request_counts: usize,
    pub uploaded_samples: usize,
    pub uploaded_request_count_entries: usize,
    pub last_upload_at: Option<DateTime<Utc>>,
    pub last_upload_result: Option<String>,
    pub source_error: bool,
    pub history_error: bool,
    #[serde(default)]
    pub latest_turn: Option<serde_json::Value>,
    #[serde(default)]
    pub hero: Option<serde_json::Value>,
}

pub struct Host {
    monitor: SourceMonitor,
    pub history: History,
    pub queue: SharingQueue,
    pub status: Status,
    history_readable: bool,
    dirty: bool,
    live: LiveResponses,
    auto: AutoSelector,
}

impl Host {
    pub fn new(paths: &Paths, settings: &Settings, sharing: bool, now: DateTime<Utc>) -> Self {
        let loaded = History::load(paths.data.join("history.json"), now);
        let history_readable = loaded.is_ok();
        let history = loaded.unwrap_or_default();
        let mut monitor = settings.monitor();
        monitor.set_checkpoints(history.checkpoints().clone());
        Self {
            monitor,
            history,
            queue: SharingQueue::new(),
            history_readable,
            dirty: false,
            live: LiveResponses::new(now),
            auto: AutoSelector::new(),
            status: Status {
                version: APP_VERSION.into(),
                started_at: Some(now),
                monitoring: true,
                sharing_requested: sharing,
                history_error: !history_readable,
                ..Status::default()
            },
        }
    }
    pub fn poll(&mut self, now: DateTime<Utc>) -> Result<()> {
        let found = self.monitor.poll(now)?;
        let outcomes = self.monitor.take_request_outcomes();
        // Live response samples are desktop display state, not another upload source.
        let mut responses = self.monitor.take_live_responses();
        responses.extend(found.iter().filter_map(ResponseMetric::from_grok_turn));
        self.live.push(responses, now);
        if self.status.sharing_active {
            self.queue.enqueue(&found, now);
            self.queue.enqueue_outcomes(&outcomes, now);
        }
        self.history.merge(&found, now);
        self.history
            .set_checkpoints(self.monitor.checkpoints(self.history.checkpoints()), now);
        self.status.source_error = self.monitor.had_source_error();
        self.dirty = true;
        Ok(())
    }
    pub fn activate(
        &mut self,
        paths: &Paths,
        loader: impl FnOnce(&Paths) -> Result<Zeroizing<[u8; 32]>>,
        now: DateTime<Utc>,
    ) -> Option<Zeroizing<[u8; 32]>> {
        if !self.status.sharing_requested || !paths.consent_valid() {
            return None;
        }
        match loader(paths) {
            Ok(key) => {
                self.queue.disable();
                self.queue.enable(now);
                self.status.sharing_active = true;
                Some(key)
            }
            Err(_) => {
                self.status.last_upload_result = Some(
                    "credential-unavailable; restart after repairing systemd credentials".into(),
                );
                None
            }
        }
    }
    pub fn deactivate(&mut self) {
        self.queue.disable();
        self.status.sharing_active = false;
    }
    pub fn finish_upload(
        &mut self,
        code: Option<u16>,
        batch: &UploadBatch,
        now: DateTime<Utc>,
    ) -> bool {
        self.status.last_upload_at = Some(now);
        self.status.last_upload_result = Some(match code {
            Some(200..=299) => {
                self.queue.ack_batch(batch);
                self.status.uploaded_samples += batch.samples.len();
                self.status.uploaded_request_count_entries += batch.request_counts.len();
                "accepted".into()
            }
            Some(400 | 413 | 422) => {
                self.queue.ack_batch(batch);
                "rejected; batch discarded".into()
            }
            Some(426) => {
                self.deactivate();
                "upgrade-required; sharing stopped".into()
            }
            Some(status) => format!("http-{status}; retry pending"),
            None => "network-error; retry pending".into(),
        });
        self.status.sharing_active
    }
    fn save(&mut self, paths: &Paths, now: DateTime<Utc>, save_history: bool) -> Result<()> {
        if save_history && self.dirty && self.history_readable {
            // Never overwrite corrupt or unreadable history. Repair is an explicit operator action.
            self.history.save(paths.data.join("history.json"))?;
            self.dirty = false;
        }
        self.status.history_turns = self.history.records().len();
        self.auto.update(now, &self.live.responses(), None);
        self.status.hero = tray_reading(
            &SelectionMode::Auto { tool: None },
            &self.live,
            self.auto.active(),
            self.history.records(),
            None,
            None,
            now,
        )
        .map(|reading| {
            serde_json::json!({
                "speed": reading.speed, "model": reading.model, "provider": reading.provider,
                "tool": reading.client, "label": match reading.kind {
                    TrayReadingKind::Live => "Response speed · last 5 responses",
                    TrayReadingKind::LatestResponse => "Response speed · latest turn",
                    TrayReadingKind::TurnFallback => "Turn throughput · latest turn",
                }
            })
        });
        self.status.latest_turn = self
            .history
            .records()
            .iter()
            .max_by_key(|m| m.completed_at)
            .map(|m| {
                serde_json::json!({
                    "tool": m.client, "model": m.model, "completed_at": m.completed_at,
                    "metric_version": m.metric_version, "output_tokens": m.output_tokens,
                    "turn_throughput_tps": m.turn_throughput_tps,
                    "duration_seconds": m.duration_seconds,
                })
            });
        self.status.pending_samples = self.queue.len();
        self.status.pending_request_counts = self.queue.request_count_len();
        self.status.updated_at = Some(now);
        write_private_file(
            paths.data.join("status.json"),
            &serde_json::to_vec_pretty(&self.status)?,
        )?;
        Ok(())
    }
    fn targets(&self) -> Vec<WatchTarget> {
        [
            "codex",
            "claude-code",
            "grok-build",
            "antigravity",
            "opencode",
            "kimi-code",
            "kimi-desktop",
            "t3-code",
        ]
        .into_iter()
        .flat_map(|id| self.monitor.watch_folders(id))
        .map(|f| WatchTarget {
            source: f.name,
            root: f.path,
            exists: f.exists,
            recursive: f.recursive,
        })
        .collect()
    }
}

pub(crate) fn client() -> Result<reqwest::Client> {
    Ok(reqwest::Client::builder()
        .https_only(true)
        .redirect(reqwest::redirect::Policy::none())
        .connect_timeout(Duration::from_secs(10))
        .timeout(Duration::from_secs(20))
        .user_agent(format!("Tokrate/{APP_VERSION}"))
        .build()?)
}

pub(crate) async fn transmit(
    transport: &reqwest::Client,
    endpoint: &str,
    request: tokrate_core::SignedRequest,
) -> Option<u16> {
    transport
        .post(endpoint)
        .header("Content-Type", "application/json")
        .header("X-Tokrate-Key", request.public_key)
        .header("X-Tokrate-Signature", request.signature)
        .body(request.body)
        .send()
        .await
        .ok()
        .map(|r| r.status().as_u16())
}

pub async fn run(paths: Paths, share: bool, once: bool) -> Result<()> {
    if share && !paths.consent_valid() {
        return Err(
            "Current sharing consent missing; run the installer/setup before enabling sharing"
                .into(),
        );
    }
    if share && once {
        return Err("scan is always local-only".into());
    }
    let _lock = paths.lock()?;
    let settings = paths.load()?;
    let mut host = Host::new(&paths, &settings, share, Utc::now());
    let mut key = host.activate(&paths, credentials::load, Utc::now());
    let transport = if key.is_some() { Some(client()?) } else { None };
    let signal = Arc::new(PollSignal::default());
    let mut watchers = Watchers::default();
    let mut last_poll = Instant::now() - Duration::from_secs(30);
    let mut last_save = Instant::now() - Duration::from_secs(10);
    let mut last_attempt = Instant::now() - Duration::from_secs(30);
    let mut upload: Option<(tokio::task::JoinHandle<Option<u16>>, UploadBatch)> = None;
    let mut terminate = tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate())?;
    let mut interrupt = tokio::signal::unix::signal(tokio::signal::unix::SignalKind::interrupt())?;
    let mut tick = tokio::time::interval(Duration::from_secs(2));
    tick.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);
    eprintln!(
        "Tokrate headless started; sharing {}. Use status for collection and upload state.",
        if host.status.sharing_active {
            "on"
        } else {
            "off"
        }
    );
    loop {
        tokio::select! {
            biased;
            _ = terminate.recv() => break,
            _ = interrupt.recv() => break,
            _ = tick.tick() => {},
        }
        let now = Utc::now();
        if host.status.sharing_active && !paths.consent_valid() {
            // The installer stops the service before changing root-managed consent. Also fail
            // closed if consent is withdrawn/corrupted while a foreground process is running.
            if let Some((task, _)) = upload.take() {
                task.abort();
                let _ = task.await;
            }
            host.deactivate();
            key.take();
            host.status.last_upload_result = Some("consent-withdrawn; sharing stopped".into());
        }
        if upload.as_ref().is_some_and(|(task, _)| task.is_finished()) {
            let (task, batch) = upload.take().unwrap();
            let result = task.await.ok().flatten();
            if !host.finish_upload(result, &batch, now) {
                key.take();
            }
        }
        watchers.sync(&host.targets(), &signal);
        let mut wake = signal.take();
        wake.change.must_rescan |= watchers.fallback_rescan_due();
        let changed = host.monitor.note_changes(&wake.change);
        let deadline = host.monitor.next_poll_deadline(now);
        if once
            || changed
            || last_poll.elapsed() >= Duration::from_secs(30)
            || deadline.is_some_and(|due| due <= now)
        {
            if host.poll(now).is_err() {
                host.status.source_error = true;
                // No raw parser error or source content is printed to the journal.
                eprintln!("Source poll failed; local monitoring will retry.");
            }
            last_poll = Instant::now();
        }
        if host.status.sharing_active
            && upload.is_none()
            && last_attempt.elapsed() >= Duration::from_secs(30)
        {
            let batch = host.queue.upload_batch(now);
            if !batch.is_empty() {
                // Fixed HTTPS origin, exact core serializer and signature. No arbitrary endpoint.
                let request = signed_request(
                    &batch.samples,
                    &batch.request_counts,
                    key.as_ref().unwrap(),
                    now,
                )?;
                let transport = transport.as_ref().unwrap().clone();
                upload = Some((
                    tokio::spawn(async move { transmit(&transport, API, request).await }),
                    batch,
                ));
                last_attempt = Instant::now();
            }
        }
        let save_history = once || last_save.elapsed() >= Duration::from_secs(10);
        host.save(&paths, now, save_history)?;
        if save_history {
            last_save = Instant::now();
        }
        if once {
            break;
        }
    }
    // SIGTERM never flushes telemetry; it cancels any in-flight request, drops the seed and saves
    // local checkpoints with history. Requests already transmitted cannot be recalled.
    if let Some((task, _)) = upload.take() {
        task.abort();
        let _ = task.await;
    }
    host.deactivate();
    key.take();
    host.status.monitoring = false;
    host.save(&paths, Utc::now(), true)?;
    Ok(())
}

pub fn status(paths: &Paths) -> Result<()> {
    use fs2::FileExt;
    let mut status =
        match tokrate_core::read_private_file(paths.data.join("status.json"), 1_048_576) {
            Ok(bytes) => serde_json::from_slice::<serde_json::Value>(&bytes)
                .map_err(|_| "Invalid status file")?,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => serde_json::json!({}),
            Err(_) => return Err("Status file is unreadable".into()),
        };
    if !status.is_object() {
        return Err("Invalid status file: expected an object".into());
    }
    let mut options = std::fs::OpenOptions::new();
    options.read(true).write(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK);
    }
    let running = options
        .open(paths.data.join("daemon.lock"))
        .ok()
        .filter(|f| f.metadata().is_ok_and(|m| m.is_file()))
        .is_some_and(|f| f.try_lock_exclusive().is_err());
    status["running"] = running.into();
    status["sharing_consent"] = paths.consent_valid().into();
    status["config_dir"] = paths.config.to_string_lossy().into_owned().into();
    status["data_dir"] = paths.data.to_string_lossy().into_owned().into();
    if !running {
        status["monitoring"] = false.into();
        status["sharing_active"] = false.into();
    }
    if let Ok(settings) = paths.load() {
        status["sources"] = settings.roots().iter().map(|(name, path)| {
            serde_json::json!({"tool": name, "path": path, "exists": path.exists()})
        }).collect::<Vec<_>>().into();
    }
    println!("{}", serde_json::to_string_pretty(&status)?);
    Ok(())
}
