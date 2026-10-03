use crate::model::TurnMetric;
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
const MAX_ARCHIVE_IDS_WHILE_LIVE_CATCHES_UP: usize = 8_192;
const RECENT_TAIL_BYTES: u64 = 262_144;

struct WatchedFile {
    live: IncrementalReader,
    archive: Option<IncrementalReader>,
    identity: Option<FileIdentity>,
    last_discovered_size: u64,
    modified_at: DateTime<Utc>,
    live_serviced: Option<(u64, DateTime<Utc>)>,
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
    files: HashMap<String, WatchedFile>,
    last_discovery: Option<DateTime<Utc>>,
    next_archive_index: usize,
    bytes_read_last_poll: usize,
}

impl Monitor {
    pub const MAX_POLL_BYTES: usize = MAX_POLL_BYTES_PER_CALL;
    pub const RECENT_TAIL_BYTES: u64 = RECENT_TAIL_BYTES;

    pub fn new(root: PathBuf) -> Self {
        Self {
            root,
            files: HashMap::new(),
            last_discovery: None,
            next_archive_index: 0,
            bytes_read_last_poll: 0,
        }
    }

    pub fn poll(&mut self, now: DateTime<Utc>) -> io::Result<Vec<TurnMetric>> {
        self.bytes_read_last_poll = 0;
        if self.last_discovery.map_or(true, |last| {
            now < last || now - last >= Duration::seconds(10)
        }) || self.files.is_empty()
        {
            self.discover_files(now)?;
            self.last_discovery = Some(now);
        }

        let mut byte_budget = MAX_POLL_BYTES_PER_CALL;
        let mut live_budget = LIVE_BUDGET_BYTES;
        let mut live_records = Vec::new();
        let mut live_keys: Vec<String> = self
            .files
            .iter()
            .filter(|(_, file)| {
                !file.live.is_caught_up()
                    || file.live_serviced.map_or(true, |(size, modified)| {
                        file.last_discovered_size > size || file.modified_at != modified
                    })
            })
            .map(|(key, _)| key.clone())
            .collect();
        live_keys.sort_by(|left, right| {
            let left_file = &self.files[left];
            let right_file = &self.files[right];
            right_file
                .modified_at
                .cmp(&left_file.modified_at)
                .then_with(|| left.cmp(right))
        });

        for key in live_keys.into_iter().take(MAX_READERS_PER_LANE) {
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
            if let Ok(records) = file.live.poll(limit) {
                live_records.extend(
                    records.into_iter().filter(|record| {
                        !file.archive_ids_while_live_catches_up.contains(&record.id)
                    }),
                );
                let consumed = file.live.bytes_read_last_poll();
                live_budget = live_budget.saturating_sub(consumed);
                byte_budget = byte_budget.saturating_sub(consumed);
                if file.live.is_caught_up() {
                    file.live_serviced = Some((file.last_discovered_size, file.modified_at));
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
                    archive.poll(limit).map(|records| {
                        (
                            records,
                            archive.bytes_read_last_poll(),
                            archive.is_caught_up() || archive.excludes_session(),
                        )
                    })
                });
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
        self.bytes_read_last_poll = MAX_POLL_BYTES_PER_CALL - byte_budget;
        let mut records: Vec<TurnMetric> = unique.into_values().collect();
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

    fn discover_files(&mut self, now: DateTime<Utc>) -> io::Result<()> {
        let cutoff = now - Duration::days(7);
        let candidates = discover_candidates(&self.root, cutoff)?;
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
                let archive = (candidate.size > RECENT_TAIL_BYTES)
                    .then(|| IncrementalReader::beginning(candidate.path.clone()));
                self.files.insert(
                    key,
                    WatchedFile {
                        live: IncrementalReader::recent_tail(candidate.path),
                        archive,
                        identity: candidate.identity,
                        last_discovered_size: candidate.size,
                        modified_at: candidate.modified_at,
                        live_serviced: None,
                        archive_ids_while_live_catches_up: HashSet::new(),
                    },
                );
            }
        }
        self.files.retain(|key, _| seen.contains(key));
        Ok(())
    }
}

fn discover_candidates(root: &Path, cutoff: DateTime<Utc>) -> io::Result<Vec<Candidate>> {
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
