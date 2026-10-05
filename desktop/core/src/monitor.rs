use crate::claude_parser::is_subagent_transcript_path;
use crate::delegation::{extend_bounded, DelegationEvent, DelegationTracker};
use crate::model::{ResponseMetric, TurnMetric};
use crate::reader::{file_identity, FileIdentity, IncrementalReader};
use chrono::{DateTime, Duration, Utc};
use std::collections::{HashMap, HashSet};
use std::fs;
use std::io;
use std::path::{Path, PathBuf};

const MAX_POLL_BYTES_PER_CALL: usize = 1_048_576;
const LIVE_BUDGET_BYTES: usize = MAX_POLL_BYTES_PER_CALL * 3 / 4;
const READER_BATCH_BYTES: usize = 65_536;
const MAX_FILES: usize = 2_000;
const MAX_DISCOVERED_PATHS: usize = 100_000;
const MAX_READERS_PER_LANE: usize = 24;
const ROTATING_CAUGHT_UP_TAIL_SLOTS: usize = 4;
const MAX_ARCHIVE_IDS_WHILE_LIVE_CATCHES_UP: usize = 8_192;
const RECENT_TAIL_BYTES: u64 = 262_144;

struct WatchedFile {
    live: IncrementalReader,
    archive: Option<IncrementalReader>,
    identity: Option<FileIdentity>,
    last_discovered_size: u64,
    modified_at: DateTime<Utc>,
    archive_ids_while_live_catches_up: HashSet<String>,
}

struct Candidate {
    path: PathBuf,
    identity: Option<FileIdentity>,
    modified_at: DateTime<Utc>,
    size: u64,
}

/// Scans Codex session JSONL files with a strict 1 MiB content-read budget per poll.
/// Recent tails and historical replay have separate cursors so a large archive cannot
/// prevent newly completed turns from reaching the host.
pub struct Monitor {
    root: PathBuf,
    format: JsonlFormat,
    files: HashMap<String, WatchedFile>,
    last_discovery: Option<DateTime<Utc>>,
    next_caught_up_index: usize,
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
            next_caught_up_index: 0,
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

    /// True while history is still being read (a replay reader or a tail not yet caught up),
    /// so work of already emitted turns may not have been seen.
    pub(crate) fn has_delegation_backlog(&self) -> bool {
        self.files
            .values()
            .any(|file| file.archive.is_some() || !file.live.is_caught_up())
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
        if self.last_discovery.map_or(true, |last| {
            now < last || now - last >= Duration::seconds(10)
        }) || self.files.is_empty()
        {
            self.discover_files(now)?;
            self.last_discovery = Some(now);
        }

        let max_bytes = max_bytes.min(MAX_POLL_BYTES_PER_CALL);
        let mut byte_budget = max_bytes;
        let mut live_budget = max_bytes * LIVE_BUDGET_BYTES / MAX_POLL_BYTES_PER_CALL;
        let mut live_records = Vec::new();
        let (live_keys, next_caught_up_index) = self.select_live_keys();
        self.next_caught_up_index = next_caught_up_index;

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
            let polled = file.live.poll(limit, now);
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
        let backlog = self.has_delegation_backlog();
        if let Some(tracker) = self.delegation.as_mut() {
            let events = std::mem::take(&mut self.delegation_events);
            records = tracker.apply(records, events, now, backlog);
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

    fn select_live_keys(&self) -> (Vec<String>, usize) {
        let mut pending = Vec::new();
        let mut caught_up = Vec::new();
        for (key, file) in &self.files {
            if file.live.is_caught_up() {
                caught_up.push(key.clone());
            } else {
                pending.push(key.clone());
            }
        }
        let recent_first = |left: &String, right: &String| {
            self.files[right]
                .modified_at
                .cmp(&self.files[left].modified_at)
                .then_with(|| left.cmp(right))
        };
        pending.sort_by(&recent_first);
        caught_up.sort_by(&recent_first);

        // Keep most live capacity on files that are still catching up or are among
        // the newest sessions. A small reserved lane rotates across older, caught-up
        // tails so an open but quiet Codex log can still surface a later append.
        let priority_capacity = MAX_READERS_PER_LANE - ROTATING_CAUGHT_UP_TAIL_SLOTS;
        let mut selected = Vec::with_capacity(MAX_READERS_PER_LANE);
        selected.extend(pending.iter().take(priority_capacity).cloned());
        let remaining_priority = priority_capacity.saturating_sub(selected.len());
        selected.extend(caught_up.iter().take(remaining_priority).cloned());

        let selected_set: HashSet<String> = selected.iter().cloned().collect();
        let rotating: Vec<&String> = caught_up
            .iter()
            .filter(|key| !selected_set.contains(key.as_str()))
            .collect();
        let rotate_count = ROTATING_CAUGHT_UP_TAIL_SLOTS.min(rotating.len());
        let next_index = if rotating.is_empty() {
            0
        } else {
            (self.next_caught_up_index + rotate_count) % rotating.len()
        };
        for offset in 0..rotate_count {
            selected.push(rotating[(self.next_caught_up_index + offset) % rotating.len()].clone());
        }

        // If there were fewer old tails than reserved slots, reclaim the unused
        // capacity for the next pending files and then the next-newest tails.
        if selected.len() < MAX_READERS_PER_LANE {
            let selected_set: HashSet<String> = selected.iter().cloned().collect();
            let remaining = MAX_READERS_PER_LANE - selected.len();
            let extras: Vec<String> = pending
                .iter()
                .chain(caught_up.iter())
                .filter(|key| !selected_set.contains(key.as_str()))
                .take(remaining)
                .cloned()
                .collect();
            selected.extend(extras);
        }
        (selected, next_index)
    }

    fn discover_files(&mut self, now: DateTime<Utc>) -> io::Result<()> {
        let cutoff = now - Duration::days(7);
        let candidates = discover_candidates(&self.root, cutoff, self.format)?;
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
                file.modified_at = candidate.modified_at;
                file.last_discovered_size = candidate.size;
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
                        archive_ids_while_live_catches_up: HashSet::new(),
                    },
                );
            }
        }
        self.files.retain(|key, _| seen.contains(key));
        Ok(())
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
            if !file_type.is_file()
                || !entry
                    .path()
                    .extension()
                    .and_then(|extension| extension.to_str())
                    .is_some_and(|extension| extension.eq_ignore_ascii_case("jsonl"))
            {
                continue;
            }
            let excluded = match format {
                JsonlFormat::Codex => false,
                JsonlFormat::Claude => {
                    let path = entry.path();
                    path.components().any(|component| {
                        component
                            .as_os_str()
                            .to_string_lossy()
                            .eq_ignore_ascii_case("subagents")
                    }) || path
                        .file_name()
                        .and_then(|name| name.to_str())
                        .is_some_and(|name| name.to_ascii_lowercase().starts_with("agent-"))
                }
                JsonlFormat::ClaudeSubagent => !is_subagent_transcript_path(&entry.path()),
            };
            if excluded {
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
    candidates.sort_by(|left, right| {
        right
            .modified_at
            .cmp(&left.modified_at)
            .then_with(|| left.path.cmp(&right.path))
    });
    Ok(candidates)
}
