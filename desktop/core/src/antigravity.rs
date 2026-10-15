//! Monitor for Antigravity (Google's agentic coding tool): the desktop app, the IDE and the `agy`
//! CLI, which keep one SQLite database per conversation under `~/.gemini`, plus T3 Code profiles.

use crate::antigravity_db::{read_database, GenerationCache};
use crate::antigravity_turns::{finished_turns_for_client, live_calls_for_client};
use crate::model::{ResponseMetric, ToolSurface, TurnMetric, ANTIGRAVITY_CLIENT, T3_CODE_CLIENT};
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
const T3_WATCH_KEY: &str = "antigravity-t3";
const T3_ACP_FOLDER: &str = "antigravity-acp";
const T3_CONVERSATIONS_FOLDER: &str = "conversations";
const MAX_T3_PROFILES: usize = 128;
const MAX_T3_PROFILE_ENTRIES: usize = 1_024;
/// The history retention: databases untouched for longer are not opened.
const RETENTION_DAYS: i64 = 7;
const MAX_DISCOVERED_PATHS: usize = 100_000;
const MAX_DATABASES: usize = 128;

struct Conversation {
    id: String,
    client: &'static str,
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
    client: &'static str,
    surface: ToolSurface,
}

/// Bounded reader for Antigravity conversation databases.
pub struct AntigravityMonitor {
    root: PathBuf,
    /// Optional separately configured root for T3 Code's Antigravity profiles. It is supplied by
    /// the desktop host only while the selected `~/.gemini` folder remains the default.
    t3_profiles_root: Option<PathBuf>,
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
        Self::with_t3_profiles_root(root, None)
    }

    pub fn with_t3_profiles_root(root: PathBuf, t3_profiles_root: Option<PathBuf>) -> Self {
        Self {
            root,
            t3_profiles_root,
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

    /// The T3 provider root contains one bounded, immediate profile level before each
    /// `antigravity-acp/conversations` folder. No profile or folder symlinks are followed.
    pub fn has_t3_conversation_folder(root: &Path) -> bool {
        !t3_conversation_folders(root).is_empty()
    }

    /// Changes the optional T3 root and schedules an immediate bounded discovery.
    pub fn set_t3_profiles_root(&mut self, root: Option<PathBuf>) {
        if self.t3_profiles_root != root {
            self.t3_profiles_root = root;
            self.needs_discovery = true;
        }
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
            for turn in finished_turns_for_client(
                &conversation.id,
                conversation.surface,
                conversation.client,
                &snapshot,
            ) {
                if !conversation.emitted.contains(&turn.execution_id) {
                    conversation.emitted.insert(turn.execution_id);
                    records.push(turn.metric);
                }
            }
            for call in
                live_calls_for_client(&conversation.id, conversation.client, &snapshot, started_at)
            {
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
            || self
                .t3_profiles_root
                .as_deref()
                .is_some_and(Self::has_t3_conversation_folder)
    }

    /// The conversation folders a host watches, each under a name of its own, with whether it
    /// exists now. Only these folders are watched: the rest of `~/.gemini` (a browser profile,
    /// caches, brain files) changes constantly and holds nothing measured.
    pub fn watch_folders(&self) -> Vec<(&'static str, PathBuf, bool, bool)> {
        let mut folders: Vec<_> = CONVERSATION_FOLDERS
            .iter()
            .zip(WATCH_KEYS)
            .map(|((folder, _), key)| {
                let path = self.root.join(folder);
                let exists = path.is_dir();
                (key, path, exists, false)
            })
            .collect();
        if let Some(root) = &self.t3_profiles_root {
            folders.push((T3_WATCH_KEY, root.clone(), is_real_directory(root), true));
        }
        folders
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
                if self
                    .t3_profiles_root
                    .as_deref()
                    .is_some_and(|root| is_t3_folder_event(root, path))
                {
                    self.needs_discovery = true;
                    noted = true;
                }
                continue;
            };
            let standard_folder = path
                .parent()
                .is_some_and(|parent| folders.iter().any(|folder| folder == parent));
            let t3_folder = self
                .t3_profiles_root
                .as_deref()
                .is_some_and(|root| is_t3_database_event(root, path));
            if !standard_folder && !t3_folder {
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

    /// Tracks the newest databases of the standard and optional T3 conversation folders and
    /// forgets the rest.
    fn discover(&mut self, now: DateTime<Utc>) {
        let cutoff = now - Duration::days(RETENTION_DAYS);
        let mut found: Vec<(DateTime<Utc>, Candidate)> = Vec::new();
        let mut visited = 0;
        for (folder, surface) in CONVERSATION_FOLDERS {
            if visited >= MAX_DISCOVERED_PATHS {
                break;
            }
            let Ok(entries) = fs::read_dir(self.root.join(folder)) else {
                continue;
            };
            for entry in entries {
                if visited >= MAX_DISCOVERED_PATHS {
                    break;
                }
                visited += 1;
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
                            client: ANTIGRAVITY_CLIENT,
                            surface,
                        },
                    ));
                }
            }
        }
        if let Some(root) = &self.t3_profiles_root {
            for folder in t3_conversation_folders(root) {
                if visited >= MAX_DISCOVERED_PATHS {
                    break;
                }
                let Ok(entries) = fs::read_dir(&folder) else {
                    continue;
                };
                for entry in entries {
                    if visited >= MAX_DISCOVERED_PATHS {
                        break;
                    }
                    visited += 1;
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
                                client: T3_CODE_CLIENT,
                                surface: ToolSurface::Other,
                            },
                        ));
                    }
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
                    client: candidate.client,
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

/// Real directories only: `Path::is_dir` follows symlinks, which discovery intentionally avoids.
fn is_real_directory(path: &Path) -> bool {
    fs::symlink_metadata(path).is_ok_and(|metadata| metadata.file_type().is_dir())
}

fn is_t3_profile_name(name: &str) -> bool {
    name.len() == 64 && name.bytes().all(|byte| byte.is_ascii_hexdigit())
}

/// The immediate profile entries are capped independently of database discovery. Profiles are
/// accepted only when every directory in their fixed layout is a real directory.
fn t3_conversation_folders(root: &Path) -> Vec<PathBuf> {
    if !is_real_directory(root) {
        return Vec::new();
    }
    let Ok(entries) = fs::read_dir(root) else {
        return Vec::new();
    };
    let mut folders = Vec::new();
    for entry in entries.take(MAX_T3_PROFILE_ENTRIES) {
        if folders.len() >= MAX_T3_PROFILES {
            break;
        }
        let Ok(entry) = entry else { continue };
        if !entry.file_type().is_ok_and(|kind| kind.is_dir()) {
            continue;
        }
        let Some(name) = entry.file_name().to_str().map(str::to_owned) else {
            continue;
        };
        if !is_t3_profile_name(&name) {
            continue;
        }
        let acp = entry.path().join(T3_ACP_FOLDER);
        let conversations = acp.join(T3_CONVERSATIONS_FOLDER);
        if is_real_directory(&acp) && is_real_directory(&conversations) {
            folders.push(conversations);
        }
    }
    folders.sort();
    folders
}

fn t3_profile_components(root: &Path, path: &Path) -> Option<Vec<String>> {
    let relative = path.strip_prefix(root).ok()?;
    relative
        .components()
        .map(|component| match component {
            std::path::Component::Normal(value) => value.to_str().map(str::to_owned),
            _ => None,
        })
        .collect()
}

/// Only the profile directory and its two fixed child folders wake discovery. File churn such as
/// settings, logs, authentication and caches is ignored.
fn is_t3_folder_event(root: &Path, path: &Path) -> bool {
    let Some(parts) = t3_profile_components(root, path) else {
        return false;
    };
    if parts.len() == 1 {
        return is_t3_profile_name(&parts[0]);
    }
    is_t3_profile_name(&parts[0])
        && ((parts.len() == 2 && parts[1] == T3_ACP_FOLDER)
            || (parts.len() == 3
                && parts[1] == T3_ACP_FOLDER
                && parts[2] == T3_CONVERSATIONS_FOLDER))
}

fn is_t3_database_event(root: &Path, path: &Path) -> bool {
    let Some(parts) = t3_profile_components(root, path) else {
        return false;
    };
    if parts.len() != 4
        || !is_t3_profile_name(&parts[0])
        || parts[1] != T3_ACP_FOLDER
        || parts[2] != T3_CONVERSATIONS_FOLDER
    {
        return false;
    }
    database_of_event(path).is_some()
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
