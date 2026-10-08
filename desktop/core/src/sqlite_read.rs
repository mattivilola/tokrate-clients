//! What every SQLite-backed source shares: opening a database strictly read-only, noticing that it
//! (or its write-ahead log) changed, a bounded memory of what was already emitted and the retry
//! delay of a database that cannot be read.

use chrono::{DateTime, Duration, Utc};
use rusqlite::{Connection, OpenFlags};
use std::collections::{HashSet, VecDeque};
use std::fs;
use std::path::{Path, PathBuf};
use std::time::{Duration as StdDuration, SystemTime};

const BUSY_TIMEOUT: StdDuration = StdDuration::from_millis(500);
/// Items remembered per database or source before the oldest are forgotten.
pub(crate) const MAX_REMEMBERED: usize = 4_096;

/// The `file:` URI of a database path with `mode=ro`. The path is percent-encoded; Windows drive
/// paths become `file:///C:/...` and backslashes become slashes.
pub(crate) fn read_only_uri(path: &Path) -> Option<String> {
    let text = path.to_str()?.replace('\\', "/");
    let mut encoded = String::with_capacity(text.len() + 24);
    encoded.push_str("file://");
    if !text.starts_with('/') {
        encoded.push('/');
    }
    let bytes = text.as_bytes();
    for (index, byte) in bytes.iter().enumerate() {
        let drive_colon =
            *byte == b':' && index == 1 && bytes[0].is_ascii_alphabetic() && !text.starts_with('/');
        if byte.is_ascii_alphanumeric()
            || matches!(byte, b'-' | b'.' | b'_' | b'~' | b'/')
            || drive_colon
        {
            encoded.push(*byte as char);
        } else {
            encoded.push_str(&format!("%{byte:02X}"));
        }
    }
    encoded.push_str("?mode=ro");
    Some(encoded)
}

/// Whether `path` is a regular file (following a symlink, like every other source file) or does
/// not exist. SQLite opens its files blocking, so a FIFO named like the database or its log would
/// stall the poll that opens it.
fn is_regular_or_absent(path: &Path) -> bool {
    fs::metadata(path).map_or(true, |metadata| metadata.is_file())
}

/// Opens a database without any way to write: a read-only `file:` URI with `mode=ro` (never
/// `immutable`, which would ignore the write-ahead log) and a busy timeout of half a second. The
/// database and its write-ahead log must be regular files.
pub(crate) fn open_read_only(path: &Path) -> rusqlite::Result<Connection> {
    if !fs::metadata(path).is_ok_and(|metadata| metadata.is_file())
        || !is_regular_or_absent(&wal_path(path))
    {
        return Err(rusqlite::Error::InvalidPath(path.to_path_buf()));
    }
    let uri =
        read_only_uri(path).ok_or_else(|| rusqlite::Error::InvalidPath(path.to_path_buf()))?;
    let flags = OpenFlags::SQLITE_OPEN_READ_ONLY
        | OpenFlags::SQLITE_OPEN_URI
        | OpenFlags::SQLITE_OPEN_NO_MUTEX;
    let connection = Connection::open_with_flags(uri, flags)?;
    connection.busy_timeout(BUSY_TIMEOUT)?;
    Ok(connection)
}

/// What changed on disk: the size and modification time of the database and its write-ahead log.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) struct DatabaseSignature {
    database: (u64, Option<SystemTime>),
    log: Option<(u64, Option<SystemTime>)>,
}

impl DatabaseSignature {
    pub fn of(path: &Path) -> Option<Self> {
        let database = fs::metadata(path).ok()?;
        let log = fs::metadata(wal_path(path))
            .ok()
            .map(|metadata| (metadata.len(), metadata.modified().ok()));
        Some(Self {
            database: (database.len(), database.modified().ok()),
            log,
        })
    }

    /// Size of the database file itself (not its log).
    pub fn database_len(&self) -> u64 {
        self.database.0
    }

    /// Last write to either file: recent activity may live only in the write-ahead log.
    pub fn modified(&self) -> Option<DateTime<Utc>> {
        [self.database.1, self.log.and_then(|log| log.1)]
            .into_iter()
            .flatten()
            .max()
            .map(DateTime::<Utc>::from)
    }
}

pub(crate) fn wal_path(path: &Path) -> PathBuf {
    let mut name = path.as_os_str().to_owned();
    name.push("-wal");
    PathBuf::from(name)
}

/// A set that forgets its oldest entries instead of growing without bound.
pub(crate) struct Remembered<T: std::hash::Hash + Eq + Clone> {
    order: VecDeque<T>,
    members: HashSet<T>,
}

impl<T: std::hash::Hash + Eq + Clone> Remembered<T> {
    pub fn new() -> Self {
        Self {
            order: VecDeque::new(),
            members: HashSet::new(),
        }
    }

    pub fn contains(&self, value: &T) -> bool {
        self.members.contains(value)
    }

    pub fn insert(&mut self, value: T) {
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

/// Delay before retrying a database after `failures` consecutive failed reads: 10 s, doubling up to
/// 5 minutes, so a permanently unreadable file is not reopened on every poll.
pub(crate) fn retry_delay(failures: u32) -> Duration {
    Duration::seconds((10_i64 << failures.saturating_sub(1).min(5)).min(300))
}
