//! Monitor for Antigravity (Google's agentic coding tool): the desktop app, the IDE and the `agy`
//! CLI, which keep one SQLite database per conversation under `~/.gemini`.

use crate::antigravity_db::{read_database, GenerationCache};
use crate::antigravity_turns::{finished_turns, live_calls};
use crate::model::{ResponseMetric, ToolSurface, TurnMetric};
use crate::monitor::{SourceChange, DISCOVERY_INTERVAL_SECONDS};
use crate::sqlite_read::{retry_delay, DatabaseSignature, Remembered};
use chrono::{DateTime, Duration, Utc};
use std::collections::{HashMap, HashSet};
use std::fs;
use std::io;
use std::path::{Path, PathBuf};

/// The data folders under the root that hold `<conversationId>.db` files, with the surface of
/// the Antigravity product that writes to each: the app, the IDE and the `agy` CLI.
const CONVERSATION_FOLDERS: [(&str, ToolSurface); 3] = [
    ("antigravity/conversations", ToolSurface::Desktop),
    ("antigravity-ide/conversations", ToolSurface::Ide),
    ("antigravity-cli/conversations", ToolSurface::Cli),
];
/// The names a host watches the three folders under (the watcher keys sources by name).
const WATCH_KEYS: [&str; 3] = ["antigravity", "antigravity-ide", "antigravity-cli"];
/// The history retention: databases untouched for longer are not opened.
const RETENTION_DAYS: i64 = 7;
const MAX_DISCOVERED_PATHS: usize = 100_000;
const MAX_DATABASES: usize = 128;

struct Conversation {
    id: String,
    /// Where the database was found.
    surface: ToolSurface,
    /// The signature the last successful read saw; `None` until one succeeds.
    read_at: Option<DatabaseSignature>,
    /// The files as last seen: refreshed by every poll and by a watcher report for this database.
    current: Option<DatabaseSignature>,
    /// Orders re-reads: databases serviced longest ago go first.
    serviced: u64,
    /// Consecutive failed reads; a failing database waits `retry_delay(failures)` before the next try.
    failures: u32,
    retry_at: Option<DateTime<Utc>>,
    emitted: Remembered<String>,
    published: Remembered<i64>,
    generations: GenerationCache,
}

struct Candidate {
    path: PathBuf,
    id: String,
    surface: ToolSurface,
}

/// Bounded reader for Antigravity conversation databases.
pub struct AntigravityMonitor {
    root: PathBuf,
    conversations: HashMap<PathBuf, Conversation>,
    last_discovery: Option<DateTime<Utc>>,
    /// A new or vanished database, a new folder or lost events: enumerate on the next poll.
    needs_discovery: bool,
    root_was_present: bool,
    /// First poll time: only model calls completed after it are published live.
    started_at: Option<DateTime<Utc>>,
    ticks: u64,
    bytes_read_last_poll: usize,
    live_responses: Vec<ResponseMetric>,
}

impl AntigravityMonitor {
    pub const MAX_POLL_BYTES: usize = 1_048_576;

    pub fn new(root: PathBuf) -> Self {
        Self {
            root,
            conversations: HashMap::new(),
            last_discovery: None,
            needs_discovery: false,
            root_was_present: false,
            started_at: None,
            ticks: 0,
            bytes_read_last_poll: 0,
            live_responses: Vec::new(),
        }
    }

    /// Whether any of a data root's conversation folders exists: `~/.gemini` alone (Gemini CLI)
    /// does not mean Antigravity is installed.
    pub fn has_conversation_folder(root: &Path) -> bool {
        CONVERSATION_FOLDERS
            .iter()
            .any(|(folder, _)| root.join(folder).is_dir())
    }

    pub fn poll(&mut self, now: DateTime<Utc>) -> io::Result<Vec<TurnMetric>> {
        self.poll_with_budget(now, Self::MAX_POLL_BYTES)
    }

    /// Re-reads changed databases, least recently serviced first, until the budget of blob bytes
    /// is used up. A database is read whole, so one that is larger than the budget is read alone
    /// and may exceed it.
    pub fn poll_with_budget(
        &mut self,
        now: DateTime<Utc>,
        max_bytes: usize,
    ) -> io::Result<Vec<TurnMetric>> {
        self.bytes_read_last_poll = 0;
        let started_at = *self.started_at.get_or_insert(now);
        let root_is_present = self.root_exists();
        if root_is_present && !self.root_was_present {
            self.needs_discovery = true;
        }
        self.root_was_present = root_is_present;
        // Enumerating is for new databases, lost events and the safety net; a poll that found
        // nothing reported opens no file and only looks at the known databases.
        if self.needs_discovery
            || self.last_discovery.is_none_or(|last| {
                now < last || now - last >= Duration::seconds(DISCOVERY_INTERVAL_SECONDS)
            })
        {
            self.needs_discovery = false;
            self.discover(now);
            self.last_discovery = Some(now);
        }
        let cutoff = now - Duration::days(RETENTION_DAYS);
        for (path, conversation) in &mut self.conversations {
            conversation.current = DatabaseSignature::of(path);
        }
        let mut stale: Vec<(PathBuf, DatabaseSignature)> = self
            .conversations
            .iter()
            .filter_map(|(path, conversation)| {
                let signature = conversation.current?;
                (signature.modified()? >= cutoff
                    && conversation.read_at != Some(signature)
                    && conversation.retry_at.is_none_or(|retry_at| retry_at <= now))
                .then(|| (path.clone(), signature))
            })
            .collect();
        stale.sort_by(|left, right| {
            self.conversations[&left.0]
                .serviced
                .cmp(&self.conversations[&right.0].serviced)
                .then_with(|| left.0.cmp(&right.0))
        });

        let mut records = Vec::new();
        for (path, signature) in stale {
            if self.bytes_read_last_poll >= max_bytes {
                break;
            }
            let Some(conversation) = self.conversations.get_mut(&path) else {
                continue;
            };
            self.ticks += 1;
            conversation.serviced = self.ticks;
            // An unreadable database (locked, corrupt, another schema) is retried with a growing delay.
            let Ok(snapshot) = read_database(&path, &mut conversation.generations) else {
                conversation.failures = conversation.failures.saturating_add(1);
                conversation.retry_at = Some(now + retry_delay(conversation.failures));
                continue;
            };
            conversation.failures = 0;
            conversation.retry_at = None;
            conversation.read_at = Some(signature);
            self.bytes_read_last_poll += snapshot.bytes_read;
            if snapshot.is_subagent {
                continue;
            }
            for turn in finished_turns(&conversation.id, conversation.surface, &snapshot) {
                if !conversation.emitted.contains(&turn.execution_id) {
                    conversation.emitted.insert(turn.execution_id);
                    records.push(turn.metric);
                }
            }
            for call in live_calls(&conversation.id, &snapshot, started_at) {
                if !conversation.published.contains(&call.step_index) {
                    conversation.published.insert(call.step_index);
                    self.live_responses.push(call.response);
                }
            }
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

    /// Whether any conversation folder exists now.
    pub fn root_exists(&self) -> bool {
        Self::has_conversation_folder(&self.root)
    }

    /// The conversation folders a host watches, each under a name of its own, with whether it
    /// exists now. Only these folders are watched: the rest of `~/.gemini` (a browser profile,
    /// caches, brain files) changes constantly and holds nothing measured.
    pub fn watch_folders(&self) -> Vec<(&'static str, PathBuf, bool)> {
        CONVERSATION_FOLDERS
            .iter()
            .zip(WATCH_KEYS)
            .map(|((folder, _), key)| {
                let path = self.root.join(folder);
                let exists = path.is_dir();
                (key, path, exists)
            })
            .collect()
    }

    /// Marks what a folder watcher reported so the next poll reads it. Only a `<id>.db` or
    /// `<id>.db-wal` directly inside a conversation folder (or such a folder itself) matters; every
    /// other path is ignored. A change to a known database refreshes its signature, and a new
    /// database, a vanished one, a folder change or a lost event triggers discovery. Paths must be
    /// spelled under the root as the monitor was created with. Returns whether a poll has work now.
    pub fn note_changes(&mut self, change: &SourceChange) -> bool {
        let mut noted = change.must_rescan;
        if change.must_rescan {
            self.needs_discovery = true;
        }
        let folders: Vec<PathBuf> = CONVERSATION_FOLDERS
            .iter()
            .map(|(folder, _)| self.root.join(folder))
            .collect();
        for path in &change.paths {
            if folders.contains(path) {
                self.needs_discovery = true;
                noted = true;
                continue;
            }
            let Some(database) = database_of_event(path) else {
                continue;
            };
            if !path
                .parent()
                .is_some_and(|parent| folders.iter().any(|folder| folder == parent))
            {
                continue;
            }
            match self.conversations.get_mut(&database) {
                Some(conversation) => match DatabaseSignature::of(&database) {
                    Some(signature) => {
                        conversation.current = Some(signature);
                        // A report that changed nothing (the files already read) leaves nothing
                        // to poll for.
                        noted |= conversation.read_at != Some(signature);
                    }
                    None => {
                        self.needs_discovery = true;
                        noted = true;
                    }
                },
                None if DatabaseSignature::of(&database).is_some() => {
                    self.needs_discovery = true;
                    noted = true;
                }
                None => {}
            }
        }
        noted
    }

    /// When the monitor must poll again if nothing else changes: `now` while a discovery is due or
    /// a changed database waits to be read (including reads the per-poll cap deferred), else the
    /// earliest retry of a database that failed to read, else `None`.
    pub fn next_poll_deadline(&self, now: DateTime<Utc>) -> Option<DateTime<Utc>> {
        if self.needs_discovery {
            return Some(now);
        }
        let cutoff = now - Duration::days(RETENTION_DAYS);
        self.conversations
            .values()
            .filter(|conversation| {
                conversation.current.is_some_and(|current| {
                    conversation.read_at != Some(current)
                        && current
                            .modified()
                            .is_some_and(|modified| modified >= cutoff)
                })
            })
            .map(|conversation| conversation.retry_at.map_or(now, |retry| retry.max(now)))
            .min()
    }

    /// Qualifying model calls completed since the last call, oldest first.
    pub fn take_live_responses(&mut self) -> Vec<ResponseMetric> {
        std::mem::take(&mut self.live_responses)
    }

    /// Tracks the newest databases of the three conversation folders and forgets the rest.
    fn discover(&mut self, now: DateTime<Utc>) {
        let cutoff = now - Duration::days(RETENTION_DAYS);
        let mut found: Vec<(DateTime<Utc>, Candidate)> = Vec::new();
        let mut visited = 0;
        for (folder, surface) in CONVERSATION_FOLDERS {
            let Ok(entries) = fs::read_dir(self.root.join(folder)) else {
                continue;
            };
            for entry in entries {
                visited += 1;
                if visited > MAX_DISCOVERED_PATHS {
                    break;
                }
                let Ok(entry) = entry else { continue };
                if !entry.file_type().is_ok_and(|kind| kind.is_file()) {
                    continue;
                }
                let name = entry.file_name();
                let Some(id) = name
                    .to_str()
                    .and_then(|name| name.strip_suffix(".db"))
                    .filter(|id| !id.is_empty() && !id.starts_with('.'))
                else {
                    continue;
                };
                let path = entry.path();
                let Some(modified) =
                    DatabaseSignature::of(&path).and_then(|signature| signature.modified())
                else {
                    continue;
                };
                if modified >= cutoff {
                    found.push((
                        modified,
                        Candidate {
                            path,
                            id: id.to_owned(),
                            surface,
                        },
                    ));
                }
            }
        }
        found.sort_by(|left, right| {
            right
                .0
                .cmp(&left.0)
                .then_with(|| left.1.path.cmp(&right.1.path))
        });
        found.truncate(MAX_DATABASES);
        let keep: HashSet<&PathBuf> = found.iter().map(|(_, candidate)| &candidate.path).collect();
        self.conversations.retain(|path, _| keep.contains(path));
        for (_, candidate) in found {
            self.conversations
                .entry(candidate.path)
                .or_insert_with(|| Conversation {
                    id: candidate.id,
                    surface: candidate.surface,
                    read_at: None,
                    current: None,
                    serviced: 0,
                    failures: 0,
                    retry_at: None,
                    emitted: Remembered::new(),
                    published: Remembered::new(),
                    generations: GenerationCache::default(),
                });
        }
    }
}

/// The database a changed path belongs to: `<id>.db` is itself and `<id>.db-wal` is its log; nothing
/// else (`.pb`, `-shm`, journals) is.
fn database_of_event(path: &Path) -> Option<PathBuf> {
    let name = path.file_name()?.to_str()?;
    let id = name
        .strip_suffix(".db")
        .or_else(|| name.strip_suffix(".db-wal"))?;
    if id.is_empty() || id.starts_with('.') {
        return None;
    }
    Some(path.with_file_name(format!("{id}.db")))
}
