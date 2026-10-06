use crate::claude_parser::is_subagent_transcript_path;
use crate::delegation::{
    extend_bounded, DelegationEvent, DelegationFileBacklog, DelegationTracker,
};
use crate::model::{
    ResponseMetric, TurnMetric, CLAUDE_METRIC_VERSION, CLAUDE_PARSER_VERSION,
    CLAUDE_SUBAGENT_METRIC_VERSION, CODEX_METRIC_VERSION, CODEX_PARSER_VERSION,
    RESPONSE_METRIC_VERSION,
};
use crate::reader::{file_identity, FileIdentity, IncrementalReader};
use chrono::{DateTime, Duration, Utc};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::collections::{HashMap, HashSet};
use std::fs;
use std::io;
use std::path::{Path, PathBuf};

const MAX_POLL_BYTES_PER_CALL: usize = 1_048_576;
const LIVE_BUDGET_BYTES: usize = MAX_POLL_BYTES_PER_CALL * 3 / 4;
const READER_BATCH_BYTES: usize = 65_536;
pub(crate) const MAX_FILES: usize = 2_000;
const MAX_DISCOVERED_PATHS: usize = 100_000;
const MAX_READERS_PER_LANE: usize = 24;
/// The folder watcher reports new and changed files, so a full enumeration only has to cover what
/// it missed. This is that safety net, and the only periodic walk.
pub(crate) const DISCOVERY_INTERVAL_SECONDS: i64 = 300;
/// How long after a read the Claude parser may still need a poll to close a turn that ended in
/// thinking: its own 30 s wait plus a second. A caught-up file is not polled otherwise.
const PENDING_FLUSH_SECONDS: i64 = 31;
/// A checkpoint is applied only to a file idle this long when the monitor starts. A turn that was
/// running when the app quit is then still read from its recent tail instead of being resumed after
/// its start.
const CHECKPOINT_MIN_QUIET_SECONDS: i64 = 600;
const MAX_ARCHIVE_IDS_WHILE_LIVE_CATCHES_UP: usize = 8_192;
const RECENT_TAIL_BYTES: u64 = 262_144;

struct WatchedFile {
    live: IncrementalReader,
    archive: Option<IncrementalReader>,
    identity: Option<FileIdentity>,
    last_discovered_size: u64,
    modified_at: DateTime<Utc>,
    /// The modification time the live reader had last serviced the file at; older than
    /// `modified_at` when the file changed since.
    live_serviced_modified_at: Option<DateTime<Utc>>,
    /// Poll time at which the live reader was created and positioned; `None` until positioned.
    live_started_at: Option<DateTime<Utc>>,
    /// Set when the file was resumed from a launch checkpoint: its content up to this modification
    /// time was not read in this run.
    skipped_through: Option<DateTime<Utc>>,
    /// Claude only: when the live reader must be polled once more so its parser can close a turn
    /// that was still waiting for a message when the file went quiet.
    flush_due_at: Option<DateTime<Utc>>,
    archive_ids_while_live_catches_up: HashSet<String>,
}

impl WatchedFile {
    /// The live reader is short of its file's end, or the file changed since it last serviced it.
    fn live_has_unread(&self) -> bool {
        !self.live.is_caught_up() || self.live_serviced_modified_at != Some(self.modified_at)
    }

    fn flush_is_due(&self, now: DateTime<Utc>) -> bool {
        self.flush_due_at.is_some_and(|due| due <= now)
    }

    fn delegation_backlog(&self) -> DelegationFileBacklog {
        DelegationFileBacklog {
            modified_at: self.modified_at,
            live_pending: self.live_has_unread(),
            archive_pending: self.archive.is_some(),
            live_started_at: self.live_started_at,
            skipped_through: self.skipped_through,
        }
    }
}

/// True when a file resumed from a checkpoint could hold work started at or after `work_start`
/// that was not read in this run.
fn files_hold_skipped_work(
    files: &HashMap<String, WatchedFile>,
    work_start: DateTime<Utc>,
) -> bool {
    files
        .values()
        .any(|file| file.delegation_backlog().skipped_work_since(work_start))
}

/// True when any file could still hold unread work that started at or after `work_start`.
fn files_hold_delegation_backlog(
    files: &HashMap<String, WatchedFile>,
    work_start: DateTime<Utc>,
) -> bool {
    files
        .values()
        .any(|file| file.delegation_backlog().blocks(work_start))
}

struct Candidate {
    path: PathBuf,
    identity: Option<FileIdentity>,
    modified_at: DateTime<Utc>,
    size: u64,
}

#[cfg(windows)]
fn refresh_idle_candidates_from_open_handles(
    candidates: &mut [Candidate],
    files: &HashMap<String, WatchedFile>,
) {
    for candidate in candidates {
        let key = candidate.path.to_string_lossy();
        let Some(_) = files.get(key.as_ref()).filter(|file| {
            file.live.is_caught_up()
                && file.live_serviced_modified_at == Some(file.modified_at)
                && candidate.size == file.last_discovered_size
                && candidate.modified_at == file.modified_at
        }) else {
            continue;
        };

        // Windows directory-entry metadata can remain stale while another process still has the
        // transcript open. Probe only unchanged, already-tracked idle files during the existing
        // five-minute discovery pass; the normal reader then handles any detected change.
        let Ok(handle) = fs::File::open(&candidate.path) else {
            continue;
        };
        let Ok(metadata) = handle.metadata() else {
            continue;
        };
        candidate.identity = file_identity(&metadata);
        candidate.size = metadata.len();
        if let Ok(modified) = metadata.modified() {
            candidate.modified_at = modified.into();
        }
    }
}

/// What a folder watcher saw below one session root since its previous report.
#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub struct SourceChange {
    /// Changed items, spelled under the root the monitor was created with.
    pub paths: HashSet<PathBuf>,
    /// Events were dropped or coalesced into "something below changed", so only a full enumeration
    /// of the folder is reliable.
    pub must_rescan: bool,
}

/// Where a previous run finished reading one session file, so the next launch does not parse it
/// again. It is valid only for the same file (identity, size, modification time) and the same
/// parser and metric versions; anything else is read from the start as usual. The path is kept as a
/// digest: local history never stores source paths.
#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SourceFileCheckpoint {
    pub(crate) path_digest: String,
    pub(crate) identity: Option<FileIdentity>,
    pub(crate) size: u64,
    pub(crate) modified_at: DateTime<Utc>,
    pub(crate) version_key: String,
}

fn path_digest(path: &str) -> String {
    format!("{:x}", Sha256::digest(path.as_bytes()))
}

/// Scans Codex session JSONL files with a strict 1 MiB content-read budget per poll.
/// Recent tails and historical replay have separate cursors so a large archive cannot
/// prevent newly completed turns from reaching the host.
///
/// Files are read when they change: the host reports a watcher's changes through
/// [`Monitor::note_changes`], and a full enumeration runs for new files, lost events and every
/// [`DISCOVERY_INTERVAL_SECONDS`]. A caught-up file that was not reported is not opened.
pub struct Monitor {
    root: PathBuf,
    format: JsonlFormat,
    files: HashMap<String, WatchedFile>,
    last_discovery: Option<DateTime<Utc>>,
    /// A change a watcher reported needs a full enumeration (a new or vanished file, lost events).
    needs_discovery: bool,
    /// The root was a folder at the previous poll; its appearing triggers discovery.
    root_was_present: bool,
    /// Launch checkpoints by path digest, consumed by the first successful discovery.
    checkpoints: HashMap<String, SourceFileCheckpoint>,
    next_archive_index: usize,
    bytes_read_last_poll: usize,
    live_responses: Vec<ResponseMetric>,
    /// Primary-turn and delegated-work events from every reader, until drained.
    delegation_events: Vec<DelegationEvent>,
    /// Codex rollouts hold primary sessions and their spawned children together, so this
    /// monitor attributes delegated work itself. Claude's two monitors are joined by their owner.
    delegation: Option<DelegationTracker>,
}

#[derive(Clone, Copy, Eq, PartialEq)]
enum JsonlFormat {
    Codex,
    /// Claude Code session transcripts; subagent transcripts are excluded.
    Claude,
    /// Claude Code `subagents/agent-*.jsonl` transcripts only.
    ClaudeSubagent,
}

impl JsonlFormat {
    fn is_claude(self) -> bool {
        matches!(self, Self::Claude | Self::ClaudeSubagent)
    }
}

impl Monitor {
    pub const MAX_POLL_BYTES: usize = MAX_POLL_BYTES_PER_CALL;
    pub const RECENT_TAIL_BYTES: u64 = RECENT_TAIL_BYTES;

    pub fn new(root: PathBuf) -> Self {
        Self::with_format(root, JsonlFormat::Codex)
    }

    pub fn new_claude(root: PathBuf) -> Self {
        Self::with_format(root, JsonlFormat::Claude)
    }

    /// Monitors only the Claude Code subagent transcripts under a projects root, with
    /// its own file cap and reader lanes so they cannot crowd out primary sessions.
    pub fn new_claude_subagents(root: PathBuf) -> Self {
        Self::with_format(root, JsonlFormat::ClaudeSubagent)
    }

    fn with_format(root: PathBuf, format: JsonlFormat) -> Self {
        Self {
            root,
            format,
            files: HashMap::new(),
            last_discovery: None,
            needs_discovery: false,
            root_was_present: false,
            checkpoints: HashMap::new(),
            next_archive_index: 0,
            bytes_read_last_poll: 0,
            live_responses: Vec::new(),
            delegation_events: Vec::new(),
            delegation: (format == JsonlFormat::Codex).then(DelegationTracker::new),
        }
    }

    /// Delegation events read since the last call. Codex monitors consume their own; this is for
    /// the owner of a Claude monitor pair.
    pub(crate) fn take_delegation_events(&mut self) -> Vec<DelegationEvent> {
        std::mem::take(&mut self.delegation_events)
    }

    /// True while a file that could hold work started at or after `work_start` still has unread
    /// content (a replay reader, a tail not yet caught up or a modification not yet read), so
    /// work of a turn that began then may not have been seen. Files last modified earlier cannot.
    pub(crate) fn has_delegation_backlog_since(&self, work_start: DateTime<Utc>) -> bool {
        files_hold_delegation_backlog(&self.files, work_start)
    }

    /// True when a file resumed from a checkpoint could hold work started at or after
    /// `work_start` that this run never read.
    pub(crate) fn has_skipped_delegation_work_since(&self, work_start: DateTime<Utc>) -> bool {
        files_hold_skipped_work(&self.files, work_start)
    }

    /// Qualifying responses the live (recent-tail) readers completed since the last call, in
    /// completion order. History replay never contributes. The first poll after a start can
    /// include responses that finished before the start; the host filters by its own launch time.
    pub fn take_live_responses(&mut self) -> Vec<ResponseMetric> {
        let mut responses = std::mem::take(&mut self.live_responses);
        responses.sort_by(|left, right| {
            left.completed_at
                .cmp(&right.completed_at)
                .then_with(|| left.id.cmp(&right.id))
        });
        responses
    }

    pub fn poll(&mut self, now: DateTime<Utc>) -> io::Result<Vec<TurnMetric>> {
        self.poll_with_budget(now, MAX_POLL_BYTES_PER_CALL)
    }

    pub fn poll_with_budget(
        &mut self,
        now: DateTime<Utc>,
        max_bytes: usize,
    ) -> io::Result<Vec<TurnMetric>> {
        self.bytes_read_last_poll = 0;
        let root_is_present = self.root_exists();
        if root_is_present && !self.root_was_present {
            self.needs_discovery = true;
        }
        self.root_was_present = root_is_present;
        if self.needs_discovery
            || self.last_discovery.map_or(true, |last| {
                now < last || now - last >= Duration::seconds(DISCOVERY_INTERVAL_SECONDS)
            })
        {
            // Settled before enumerating, so a failing walk is retried by the safety net rather
            // than on every poll.
            self.needs_discovery = false;
            self.last_discovery = Some(now);
            self.discover_files(now)?;
        }

        let max_bytes = max_bytes.min(MAX_POLL_BYTES_PER_CALL);
        let mut byte_budget = max_bytes;
        let mut live_budget = max_bytes * LIVE_BUDGET_BYTES / MAX_POLL_BYTES_PER_CALL;
        let mut live_records = Vec::new();
        let live_keys = self.select_live_keys(now);
        let mut file_vanished = false;

        for key in live_keys {
            if live_budget == 0 {
                break;
            }
            let Some(file) = self.files.get_mut(&key) else {
                continue;
            };
            let limit = READER_BATCH_BYTES.min(live_budget).min(byte_budget);
            if limit == 0 {
                break;
            }
            if file.flush_is_due(now) {
                file.flush_due_at = None;
            }
            let polled = file.live.poll(limit, now);
            match &polled {
                Ok(_) => file.live_serviced_modified_at = Some(file.modified_at),
                Err(error) => file_vanished |= error.kind() == io::ErrorKind::NotFound,
            }
            if self.format.is_claude() && file.live.bytes_read_last_poll() > 0 {
                file.flush_due_at = Some(now + Duration::seconds(PENDING_FLUSH_SECONDS));
            }
            // A reader reset to the start of a replaced file is positioned anew later.
            if !file.live.is_positioned() {
                file.live_started_at = None;
            } else if file.live_started_at.is_none() {
                file.live_started_at = Some(now);
            }
            self.live_responses.extend(file.live.take_responses());
            extend_bounded(
                &mut self.delegation_events,
                file.live.take_delegation_events(),
            );
            if let Ok(records) = polled {
                live_records.extend(
                    records.into_iter().filter(|record| {
                        !file.archive_ids_while_live_catches_up.contains(&record.id)
                    }),
                );
                let consumed = file.live.bytes_read_last_poll();
                live_budget = live_budget.saturating_sub(consumed);
                byte_budget = byte_budget.saturating_sub(consumed);
                if file.live.is_caught_up() {
                    file.archive_ids_while_live_catches_up.clear();
                }
                if file.live.excludes_session() {
                    file.archive = None;
                }
            }
        }

        let mut archive_records = Vec::new();
        let mut archive_keys: Vec<String> = self
            .files
            .iter()
            .filter_map(|(key, file)| file.archive.as_ref().map(|_| key.clone()))
            .collect();
        archive_keys.sort();
        if !archive_keys.is_empty() {
            let mut processed = 0;
            let steps = MAX_READERS_PER_LANE.min(archive_keys.len());
            for step in 0..steps {
                if byte_budget == 0 {
                    break;
                }
                let index = (self.next_archive_index + step) % archive_keys.len();
                let key = &archive_keys[index];
                let Some(file) = self.files.get_mut(key) else {
                    continue;
                };
                if file.archive.is_none() {
                    continue;
                }
                let limit = READER_BATCH_BYTES.min(byte_budget);
                let archive_result = file.archive.as_mut().map(|archive| {
                    archive.poll(limit, now).map(|records| {
                        (
                            records,
                            archive.bytes_read_last_poll(),
                            archive.is_caught_up() || archive.excludes_session(),
                        )
                    })
                });
                if let Some(archive) = file.archive.as_mut() {
                    extend_bounded(
                        &mut self.delegation_events,
                        archive.take_delegation_events(),
                    );
                }
                if let Some(Err(error)) = &archive_result {
                    file_vanished |= error.kind() == io::ErrorKind::NotFound;
                }
                if let Some(Ok((records, bytes_read, is_done))) = archive_result {
                    if !file.live.is_caught_up() {
                        for record in &records {
                            if file.archive_ids_while_live_catches_up.len()
                                < MAX_ARCHIVE_IDS_WHILE_LIVE_CATCHES_UP
                            {
                                file.archive_ids_while_live_catches_up
                                    .insert(record.id.clone());
                            }
                        }
                    }
                    archive_records.extend(records);
                    byte_budget = byte_budget.saturating_sub(bytes_read);
                    if is_done {
                        file.archive = None;
                    }
                }
                processed += 1;
            }
            self.next_archive_index = (self.next_archive_index + processed) % archive_keys.len();
        }

        // Discovery drops a file that is gone; until then it would fail again on every poll.
        self.needs_discovery |= file_vanished;

        // The archive parser sees complete turn context and wins when its ID overlaps the tail.
        let mut unique = HashMap::new();
        for record in live_records {
            unique.insert(record.id.clone(), record);
        }
        for record in archive_records {
            unique.insert(record.id.clone(), record);
        }
        self.bytes_read_last_poll = max_bytes - byte_budget;
        let mut records: Vec<TurnMetric> = unique.into_values().collect();
        if let Some(tracker) = self.delegation.as_mut() {
            let events = std::mem::take(&mut self.delegation_events);
            let files = &self.files;
            records = tracker.apply(
                records,
                events,
                now,
                |work_start| files_hold_delegation_backlog(files, work_start),
                |work_start| files_hold_skipped_work(files, work_start),
            );
        }
        records.sort_by(|left, right| {
            right
                .completed_at
                .cmp(&left.completed_at)
                .then_with(|| left.id.cmp(&right.id))
        });
        Ok(records)
    }

    pub fn bytes_read_last_poll(&self) -> usize {
        self.bytes_read_last_poll
    }

    /// The files whose live reader has something to do: unread bytes, a modification not yet
    /// read (reported by the watcher or seen by discovery) or a parser flush that came due. A
    /// caught-up file nobody reported stays closed. Newest first, within the lane's reader cap.
    fn select_live_keys(&self, now: DateTime<Utc>) -> Vec<String> {
        let mut selected: Vec<&String> = self
            .files
            .iter()
            .filter(|(_, file)| file.live_has_unread() || file.flush_is_due(now))
            .map(|(key, _)| key)
            .collect();
        selected.sort_by(|left, right| {
            self.files[*right]
                .modified_at
                .cmp(&self.files[*left].modified_at)
                .then_with(|| left.cmp(right))
        });
        selected
            .into_iter()
            .take(MAX_READERS_PER_LANE)
            .cloned()
            .collect()
    }

    pub fn root_exists(&self) -> bool {
        self.root.is_dir()
    }

    /// Marks what a folder watcher reported so the next poll reads it: a changed known file is
    /// read again, and a new file this monitor includes, a vanished one or lost events trigger a
    /// full enumeration. Paths must be spelled under the root as the monitor was created with.
    /// Returns whether anything is now pending.
    pub fn note_changes(&mut self, change: &SourceChange) -> bool {
        let mut noted = change.must_rescan;
        if change.must_rescan {
            self.needs_discovery = true;
        }
        for path in &change.paths {
            let key = path.to_string_lossy().into_owned();
            if self.files.contains_key(&key) {
                self.note_known_file(&key, path);
                noted = true;
            } else if self.includes(path) && fs::metadata(path).is_ok_and(|meta| meta.is_file()) {
                self.needs_discovery = true;
                noted = true;
            }
        }
        noted
    }

    fn note_known_file(&mut self, key: &str, path: &Path) {
        let Some(metadata) = fs::metadata(path).ok().filter(|meta| meta.is_file()) else {
            self.needs_discovery = true;
            return;
        };
        let Some(file) = self.files.get_mut(key) else {
            return;
        };
        let identity = file_identity(&metadata);
        let replaced = file.identity.is_some() && identity.is_some() && file.identity != identity
            || metadata.len() < file.last_discovered_size;
        if replaced {
            // Read again from the start by the next enumeration, like any new file.
            self.files.remove(key);
            self.needs_discovery = true;
            return;
        }
        if let Ok(modified) = metadata.modified() {
            file.modified_at = modified.into();
        }
        file.last_discovered_size = metadata.len();
        file.live_serviced_modified_at = None;
    }

    /// Whether enumeration would pick `path` up: a transcript of this format below the root and
    /// outside hidden folders.
    fn includes(&self, path: &Path) -> bool {
        path.strip_prefix(&self.root).is_ok_and(|relative| {
            !relative
                .components()
                .any(|component| component.as_os_str().to_string_lossy().starts_with('.'))
        }) && format_includes(self.format, path)
    }

    /// `now` while any reader has bytes left to read or discovery is waiting; else the earliest
    /// time alone can change something (a Claude parser flush, a delegated turn settling); `None`
    /// when only a new write can make a poll useful.
    pub fn next_poll_deadline(&self, now: DateTime<Utc>) -> Option<DateTime<Utc>> {
        if self.needs_discovery
            || self
                .files
                .values()
                .any(|file| file.live_has_unread() || file.archive.is_some())
        {
            return Some(now);
        }
        let flush = self
            .files
            .values()
            .filter_map(|file| file.flush_due_at)
            .min();
        let settle = self
            .delegation
            .as_ref()
            .and_then(|tracker| tracker.next_deadline(now));
        // Both are in the future or already due; due means poll now.
        flush
            .into_iter()
            .chain(settle)
            .min()
            .map(|due| due.max(now))
    }

    /// Hands the monitor the checkpoints a previous run saved. They apply to files the first
    /// successful discovery finds, so this belongs before the first poll.
    pub fn set_checkpoints(&mut self, checkpoints: Vec<SourceFileCheckpoint>) {
        self.checkpoints = checkpoints
            .into_iter()
            .map(|checkpoint| (checkpoint.path_digest.clone(), checkpoint))
            .collect();
    }

    /// The files a later launch can skip: fully read (no replay reader, live reader caught up on a
    /// line boundary, no modification or parser flush pending), newest first. `None` means keep
    /// the previously saved set: nothing has been enumerated yet, or a primary turn still waits
    /// for its delegated output and a launch from these positions would never see the work behind
    /// it. A Claude monitor has no tracker of its own: the owner of the pair applies that rule.
    pub fn checkpoints(&self) -> Option<Vec<SourceFileCheckpoint>> {
        // Before the first enumeration the monitor knows no files, which is not "nothing was read".
        if self.last_discovery.is_none()
            || self
                .delegation
                .as_ref()
                .is_some_and(DelegationTracker::has_pending)
        {
            return None;
        }
        let version_key = self.version_key();
        let mut entries: Vec<(&String, &WatchedFile, SourceFileCheckpoint)> = self
            .files
            .iter()
            .filter_map(|(key, file)| {
                let size = file.live.checkpoint_offset()?;
                let identity = file.live.identity().or(file.identity.as_ref())?.clone();
                (file.archive.is_none()
                    && file.live_serviced_modified_at == Some(file.modified_at)
                    && file.flush_due_at.is_none()
                    && size == file.last_discovered_size)
                    .then(|| {
                        (
                            key,
                            file,
                            SourceFileCheckpoint {
                                path_digest: path_digest(key),
                                identity: Some(identity),
                                size,
                                modified_at: file.modified_at,
                                version_key: version_key.clone(),
                            },
                        )
                    })
            })
            .collect();
        entries.sort_by(|left, right| {
            right
                .1
                .modified_at
                .cmp(&left.1.modified_at)
                .then_with(|| left.0.cmp(right.0))
        });
        Some(
            entries
                .into_iter()
                .take(MAX_FILES)
                .map(|(_, _, checkpoint)| checkpoint)
                .collect(),
        )
    }

    /// Identifies what parsed the file: a checkpoint from another parser or metric version is void.
    fn version_key(&self) -> String {
        let (parser, metric) = match self.format {
            JsonlFormat::Codex => (CODEX_PARSER_VERSION, CODEX_METRIC_VERSION),
            JsonlFormat::Claude => (CLAUDE_PARSER_VERSION, CLAUDE_METRIC_VERSION),
            JsonlFormat::ClaudeSubagent => (CLAUDE_PARSER_VERSION, CLAUDE_SUBAGENT_METRIC_VERSION),
        };
        format!("{parser}|{metric}|{RESPONSE_METRIC_VERSION}")
    }

    /// The checkpoint that says this newly found file was already read as it is now.
    fn matching_checkpoint(&self, candidate: &Candidate, now: DateTime<Utc>) -> Option<u64> {
        let checkpoint = self
            .checkpoints
            .get(&path_digest(&candidate.path.to_string_lossy()))?;
        (checkpoint.identity.is_some()
            && checkpoint.identity == candidate.identity
            && checkpoint.size == candidate.size
            && checkpoint.modified_at == candidate.modified_at
            && checkpoint.version_key == self.version_key()
            && now - candidate.modified_at >= Duration::seconds(CHECKPOINT_MIN_QUIET_SECONDS))
        .then_some(checkpoint.size)
    }

    fn discover_files(&mut self, now: DateTime<Utc>) -> io::Result<()> {
        let cutoff = now - Duration::days(7);
        let mut candidates = discover_candidates(&self.root, cutoff, self.format)?;
        #[cfg(windows)]
        refresh_idle_candidates_from_open_handles(&mut candidates, &self.files);
        candidates.sort_by(|left, right| {
            right
                .modified_at
                .cmp(&left.modified_at)
                .then_with(|| left.path.cmp(&right.path))
        });
        let mut seen = HashSet::new();
        for candidate in candidates.into_iter().take(MAX_FILES) {
            let key = candidate.path.to_string_lossy().into_owned();
            seen.insert(key.clone());
            let needs_reset = self.files.get(&key).is_some_and(|file| {
                file.identity.is_some()
                    && candidate.identity.is_some()
                    && file.identity != candidate.identity
                    || candidate.size < file.last_discovered_size
            });
            if needs_reset {
                self.files.remove(&key);
            }
            if let Some(file) = self.files.get_mut(&key) {
                // A change the watcher missed: read the file again.
                if file.modified_at != candidate.modified_at
                    || file.last_discovered_size != candidate.size
                {
                    file.live_serviced_modified_at = None;
                }
                file.modified_at = candidate.modified_at;
                file.last_discovered_size = candidate.size;
            } else if let Some(offset) = self.matching_checkpoint(&candidate, now) {
                // Read to this point by a previous run: nothing to replay, and the live reader
                // starts at the end of the file.
                self.files.insert(
                    key,
                    WatchedFile {
                        live: if self.format.is_claude() {
                            IncrementalReader::resumed_claude(candidate.path, offset)
                        } else {
                            IncrementalReader::resumed(candidate.path, offset)
                        },
                        archive: None,
                        identity: candidate.identity,
                        last_discovered_size: candidate.size,
                        modified_at: candidate.modified_at,
                        live_serviced_modified_at: Some(candidate.modified_at),
                        live_started_at: Some(now),
                        skipped_through: Some(candidate.modified_at),
                        flush_due_at: None,
                        archive_ids_while_live_catches_up: HashSet::new(),
                    },
                );
            } else {
                let archive = (candidate.size > RECENT_TAIL_BYTES).then(|| {
                    if self.format.is_claude() {
                        IncrementalReader::beginning_claude(candidate.path.clone())
                    } else {
                        IncrementalReader::beginning(candidate.path.clone())
                    }
                });
                self.files.insert(
                    key,
                    WatchedFile {
                        live: if self.format.is_claude() {
                            IncrementalReader::recent_tail_claude(candidate.path)
                        } else {
                            IncrementalReader::recent_tail(candidate.path)
                        },
                        archive,
                        identity: candidate.identity,
                        last_discovered_size: candidate.size,
                        modified_at: candidate.modified_at,
                        live_serviced_modified_at: None,
                        live_started_at: None,
                        skipped_through: None,
                        flush_due_at: None,
                        archive_ids_while_live_catches_up: HashSet::new(),
                    },
                );
            }
        }
        self.files.retain(|key, _| seen.contains(key));
        self.checkpoints.clear();
        Ok(())
    }
}

/// Whether a session file of this format is a JSONL transcript the monitor reads: Claude's primary
/// and subagent monitors split the same folder between them.
fn format_includes(format: JsonlFormat, path: &Path) -> bool {
    if !path
        .extension()
        .and_then(|extension| extension.to_str())
        .is_some_and(|extension| extension.eq_ignore_ascii_case("jsonl"))
    {
        return false;
    }
    match format {
        JsonlFormat::Codex => true,
        JsonlFormat::Claude => {
            !path.components().any(|component| {
                component
                    .as_os_str()
                    .to_string_lossy()
                    .eq_ignore_ascii_case("subagents")
            }) && !path
                .file_name()
                .and_then(|name| name.to_str())
                .is_some_and(|name| name.to_ascii_lowercase().starts_with("agent-"))
        }
        JsonlFormat::ClaudeSubagent => is_subagent_transcript_path(path),
    }
}

fn discover_candidates(
    root: &Path,
    cutoff: DateTime<Utc>,
    format: JsonlFormat,
) -> io::Result<Vec<Candidate>> {
    let mut directories = vec![root.to_path_buf()];
    let mut candidates = Vec::new();
    let mut visited_entries = 0;
    while let Some(directory) = directories.pop() {
        let entries = match fs::read_dir(&directory) {
            Ok(entries) => entries,
            Err(error) if directory.as_path() == root => return Err(error),
            Err(_) => continue,
        };
        for entry in entries {
            let Ok(entry) = entry else { continue };
            visited_entries += 1;
            if visited_entries > MAX_DISCOVERED_PATHS {
                break;
            }
            let name = entry.file_name();
            if name.to_string_lossy().starts_with('.') {
                continue;
            }
            let Ok(file_type) = entry.file_type() else {
                continue;
            };
            if file_type.is_dir() {
                directories.push(entry.path());
                continue;
            }
            if !file_type.is_file() {
                continue;
            }
            if !format_includes(format, &entry.path()) {
                continue;
            }
            let Ok(metadata) = entry.metadata() else {
                continue;
            };
            let Ok(modified) = metadata.modified() else {
                continue;
            };
            let modified_at: DateTime<Utc> = modified.into();
            if modified_at < cutoff {
                continue;
            }
            candidates.push(Candidate {
                path: entry.path(),
                identity: file_identity(&metadata),
                modified_at,
                size: metadata.len(),
            });
        }
        if visited_entries > MAX_DISCOVERED_PATHS {
            break;
        }
    }
    Ok(candidates)
}
