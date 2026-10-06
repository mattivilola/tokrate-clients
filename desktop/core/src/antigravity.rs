//! Monitor for Antigravity (Google's agentic coding tool): the desktop app, the IDE and the `agy`
//! CLI, which keep one SQLite database per conversation under `~/.gemini`.

use crate::antigravity_db::read_database;
use crate::antigravity_turns::{finished_turns, live_calls};
use crate::model::{ResponseMetric, TurnMetric};
use chrono::{DateTime, Duration, Utc};
use std::collections::{HashMap, HashSet, VecDeque};
use std::fs;
use std::io;
use std::path::{Path, PathBuf};
use std::time::SystemTime;

/// The data folders under the root that hold `<conversationId>.db` files.
const CONVERSATION_FOLDERS: [&str; 3] = [
    "antigravity/conversations",
    "antigravity-ide/conversations",
    "antigravity-cli/conversations",
];
/// The history retention: databases untouched for longer are not opened.
const RETENTION_DAYS: i64 = 7;
const MAX_DISCOVERED_PATHS: usize = 100_000;
const MAX_DATABASES: usize = 128;
/// Executions and live step indexes remembered per database.
const MAX_REMEMBERED: usize = 4_096;
const DISCOVERY_SECONDS: i64 = 10;

/// What changed on disk: the size and modification time of the database and its write-ahead log.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
struct Signature {
    database: (u64, Option<SystemTime>),
    log: Option<(u64, Option<SystemTime>)>,
}

impl Signature {
    fn of(path: &Path) -> Option<Self> {
        let database = fs::metadata(path).ok()?;
        let log = fs::metadata(wal_path(path))
            .ok()
            .map(|metadata| (metadata.len(), metadata.modified().ok()));
        Some(Self {
            database: (database.len(), database.modified().ok()),
            log,
        })
    }

    /// Last write to either file: recent activity may live only in the write-ahead log.
    fn modified(&self) -> Option<DateTime<Utc>> {
        [self.database.1, self.log.and_then(|log| log.1)]
            .into_iter()
            .flatten()
            .max()
            .map(DateTime::<Utc>::from)
    }
}

fn wal_path(path: &Path) -> PathBuf {
    let mut name = path.as_os_str().to_owned();
    name.push("-wal");
    PathBuf::from(name)
}

/// A set that forgets its oldest entries instead of growing without bound.
struct Remembered<T: std::hash::Hash + Eq + Clone> {
    order: VecDeque<T>,
    members: HashSet<T>,
}

impl<T: std::hash::Hash + Eq + Clone> Remembered<T> {
    fn new() -> Self {
        Self {
            order: VecDeque::new(),
            members: HashSet::new(),
        }
    }

    fn contains(&self, value: &T) -> bool {
        self.members.contains(value)
    }

    fn insert(&mut self, value: T) {
        if self.members.insert(value.clone()) {
            self.order.push_back(value);
            while self.order.len() > MAX_REMEMBERED {
                if let Some(oldest) = self.order.pop_front() {
                    self.members.remove(&oldest);
                }
            }
        }
    }
}

struct Conversation {
    id: String,
    /// The signature the last successful read saw; `None` until one succeeds.
    read_at: Option<Signature>,
    /// Orders re-reads: databases serviced longest ago go first.
    serviced: u64,
    emitted: Remembered<String>,
    published: Remembered<i64>,
}

struct Candidate {
    path: PathBuf,
    id: String,
}

/// Bounded reader for Antigravity conversation databases.
pub struct AntigravityMonitor {
    root: PathBuf,
    conversations: HashMap<PathBuf, Conversation>,
    last_discovery: Option<DateTime<Utc>>,
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
            .any(|folder| root.join(folder).is_dir())
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
        if self
            .last_discovery
            .is_none_or(|last| now < last || now - last >= Duration::seconds(DISCOVERY_SECONDS))
        {
            self.discover(now);
            self.last_discovery = Some(now);
        }
        let cutoff = now - Duration::days(RETENTION_DAYS);
        let mut stale: Vec<(PathBuf, Signature)> = self
            .conversations
            .iter()
            .filter_map(|(path, conversation)| {
                let signature = Signature::of(path)?;
                (signature.modified()? >= cutoff && conversation.read_at != Some(signature))
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
            // An unreadable database is skipped for now and retried on the next poll.
            let Ok(snapshot) = read_database(&path) else {
                continue;
            };
            conversation.read_at = Some(signature);
            self.bytes_read_last_poll += snapshot.bytes_read;
            if snapshot.is_subagent {
                continue;
            }
            for turn in finished_turns(&conversation.id, &snapshot) {
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

    /// Qualifying model calls completed since the last call, oldest first.
    pub fn take_live_responses(&mut self) -> Vec<ResponseMetric> {
        std::mem::take(&mut self.live_responses)
    }

    /// Tracks the newest databases of the three conversation folders and forgets the rest.
    fn discover(&mut self, now: DateTime<Utc>) {
        let cutoff = now - Duration::days(RETENTION_DAYS);
        let mut found: Vec<(DateTime<Utc>, Candidate)> = Vec::new();
        let mut visited = 0;
        for folder in CONVERSATION_FOLDERS {
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
                    Signature::of(&path).and_then(|signature| signature.modified())
                else {
                    continue;
                };
                if modified >= cutoff {
                    found.push((
                        modified,
                        Candidate {
                            path,
                            id: id.to_owned(),
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
                    read_at: None,
                    serviced: 0,
                    emitted: Remembered::new(),
                    published: Remembered::new(),
                });
        }
    }
}
