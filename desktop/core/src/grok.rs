use crate::model::{TurnMetric, GROK_CLIENT, GROK_METRIC_VERSION, GROK_PARSER_VERSION};
use crate::reader::{file_identity, FileIdentity, MAX_LINE_BYTES};
use chrono::{DateTime, Duration, Utc};
use serde_json::{Map, Value};
use sha2::{Digest, Sha256};
use std::collections::{HashMap, HashSet};
use std::fs::{self, File};
use std::io::{self, Read, Seek, SeekFrom};
use std::path::{Path, PathBuf};

const MAX_DISCOVERED_PATHS: usize = 100_000;
const MAX_SESSIONS: usize = 128;
const MAX_USAGE_BYTES: u64 = 262_144;
const MAX_COMPLETED_TURNS: usize = 4_096;
const MAX_SESSIONS_PER_POLL: usize = 8;
const PER_FILE_BUDGET: usize = 32_768;

#[derive(Clone)]
struct Candidate {
    key: String,
    events_path: PathBuf,
    usage_path: PathBuf,
    modified_at: DateTime<Utc>,
}

struct StartedTurn {
    number: u64,
    started_at: DateTime<Utc>,
    session_id: String,
    valid: bool,
}

#[derive(Clone)]
struct CompletedTurn {
    number: u64,
    started_at: DateTime<Utc>,
    completed_at: DateTime<Utc>,
    session_id: String,
    next_primary_started_at: Option<DateTime<Utc>>,
    valid: bool,
}

#[derive(Default)]
struct EventState {
    session_id: Option<String>,
    active: Option<StartedTurn>,
    suppress_until_end: bool,
    completed: Vec<CompletedTurn>,
    seen_numbers: HashSet<u64>,
    duplicate_numbers: HashSet<u64>,
}

struct EventReader {
    path: PathBuf,
    offset: u64,
    pending: Vec<u8>,
    identity: Option<FileIdentity>,
    state: EventState,
    bytes_read_last_poll: usize,
}

impl EventReader {
    fn new(path: PathBuf) -> Self {
        Self {
            identity: fs::metadata(&path)
                .ok()
                .and_then(|metadata| file_identity(&metadata)),
            path,
            offset: 0,
            pending: Vec::new(),
            state: EventState::default(),
            bytes_read_last_poll: 0,
        }
    }

    fn poll(&mut self, budget: usize) -> io::Result<()> {
        self.bytes_read_last_poll = 0;
        if budget == 0 {
            return Ok(());
        }
        let mut file = File::open(&self.path)?;
        let metadata = file.metadata()?;
        let identity = file_identity(&metadata);
        if metadata.len() < self.offset
            || (self.identity.is_some() && identity.is_some() && self.identity != identity)
        {
            self.offset = 0;
            self.pending.clear();
            self.state = EventState::default();
        }
        self.identity = identity;
        if metadata.len() <= self.offset {
            return Ok(());
        }
        let count = (metadata.len() - self.offset).min(budget as u64) as usize;
        file.seek(SeekFrom::Start(self.offset))?;
        let mut bytes = vec![0; count];
        let mut total = 0;
        while total < count {
            let amount = file.read(&mut bytes[total..])?;
            if amount == 0 {
                break;
            }
            total += amount;
        }
        bytes.truncate(total);
        self.offset += total as u64;
        self.bytes_read_last_poll = total;
        self.pending.extend_from_slice(&bytes);
        self.consume_lines();
        Ok(())
    }

    fn consume_lines(&mut self) {
        let mut start = 0;
        while let Some(relative) = self.pending[start..].iter().position(|byte| *byte == b'\n') {
            let end = start + relative;
            if end - start <= MAX_LINE_BYTES {
                if let Ok(value) = serde_json::from_slice::<Value>(&self.pending[start..end]) {
                    self.consume_event(&value);
                }
            }
            start = end + 1;
        }
        if start > 0 {
            self.pending.drain(..start);
        }
        if self.pending.len() > MAX_LINE_BYTES {
            self.pending.clear();
        }
    }

    fn consume_event(&mut self, value: &Value) {
        let Some(event) = value.as_object() else {
            return;
        };
        if event.get("schema_version").and_then(Value::as_str) != Some("1.0") {
            return;
        }
        match event.get("type").and_then(Value::as_str) {
            Some("turn_started") => self.start(event),
            Some("turn_ended") => self.end(event),
            _ => {}
        }
    }

    fn start(&mut self, event: &Map<String, Value>) {
        let is_primary =
            event.get("session_relationship").and_then(Value::as_str) == Some("primary");
        if is_primary {
            if let (Some(started_at), Some(session_id)) = (
                parse_date(event.get("ts")),
                event
                    .get("session_id")
                    .and_then(Value::as_str)
                    .filter(|value| safe_identifier(value, 512)),
            ) {
                for turn in &mut self.state.completed {
                    if turn.session_id == session_id && turn.next_primary_started_at.is_none() {
                        turn.next_primary_started_at = Some(started_at);
                    }
                }
            }
        }
        if event.get("session_relationship").and_then(Value::as_str) == Some("subagent") {
            if let Some(active) = self.state.active.as_mut() {
                active.valid = false;
            }
            self.state.suppress_until_end = true;
            return;
        }
        if event.get("session_relationship").and_then(Value::as_str) != Some("primary") {
            if let Some(active) = self.state.active.as_mut() {
                active.valid = false;
            }
            self.state.suppress_until_end = true;
            return;
        }
        if self.state.suppress_until_end {
            return;
        }
        if let Some(active) = self.state.active.as_mut() {
            // Grok's turn_ended event has no turn number. Nested or repeated starts
            // cannot be paired reliably, so discard through the next end marker.
            active.valid = false;
            self.state.suppress_until_end = true;
            return;
        }
        let Some(number) = event.get("turn_number").and_then(Value::as_u64) else {
            self.state.suppress_until_end = true;
            return;
        };
        let Some(started_at) = parse_date(event.get("ts")) else {
            self.state.suppress_until_end = true;
            return;
        };
        let Some(session_id) = event
            .get("session_id")
            .and_then(Value::as_str)
            .filter(|value| safe_identifier(value, 512))
        else {
            self.state.suppress_until_end = true;
            return;
        };
        if self
            .state
            .session_id
            .as_deref()
            .is_some_and(|known| known != session_id)
        {
            self.state.suppress_until_end = true;
            return;
        }
        self.state.session_id = Some(session_id.to_owned());
        if !self.state.seen_numbers.insert(number) {
            self.state.duplicate_numbers.insert(number);
            for turn in &mut self.state.completed {
                if turn.number == number {
                    turn.valid = false;
                }
            }
        }
        self.state.active = Some(StartedTurn {
            number,
            started_at,
            session_id: session_id.to_owned(),
            valid: !self.state.duplicate_numbers.contains(&number),
        });
    }

    fn end(&mut self, event: &Map<String, Value>) {
        if self.state.suppress_until_end {
            self.state.suppress_until_end = false;
            self.state.active = None;
            return;
        }
        let Some(active) = self.state.active.take() else {
            return;
        };
        if event.get("session_id").is_some() {
            let Some(session_id) = event
                .get("session_id")
                .and_then(Value::as_str)
                .filter(|value| safe_identifier(value, 512))
            else {
                return;
            };
            if session_id != active.session_id {
                return;
            }
        }
        if event.get("outcome").and_then(Value::as_str) != Some("completed") {
            return;
        }
        let Some(completed_at) = parse_date(event.get("ts")) else {
            return;
        };
        if !active.valid || self.state.duplicate_numbers.contains(&active.number) {
            return;
        }
        if self.state.completed.len() >= MAX_COMPLETED_TURNS {
            self.state.completed.remove(0);
        }
        self.state.completed.push(CompletedTurn {
            number: active.number,
            started_at: active.started_at,
            completed_at,
            session_id: active.session_id,
            next_primary_started_at: None,
            valid: true,
        });
    }
}

#[derive(Clone)]
struct UsageTurn {
    number: u64,
    ended_at: Option<DateTime<Utc>>,
    output_tokens: Option<i64>,
    reasoning_tokens: Option<i64>,
    incomplete: Option<bool>,
    model_usage: Option<Value>,
}

struct UsageSnapshot {
    session_id: Option<String>,
    updated_at: DateTime<Utc>,
    client_version: Option<String>,
    turns: Vec<UsageTurn>,
}

impl UsageSnapshot {
    fn parse(bytes: &[u8]) -> Option<Self> {
        let root: Value = serde_json::from_slice(bytes).ok()?;
        let object = root.as_object()?;
        let session = object.get("session").and_then(Value::as_object);
        let session_id = object
            .get("sessionId")
            .and_then(Value::as_str)
            .filter(|value| safe_identifier(value, 512))
            .map(str::to_owned);
        let updated_at = parse_date(object.get("updatedAt"))?;
        let client_version = object
            .get("clientVersion")
            .or_else(|| session.and_then(|value| value.get("clientVersion")))
            .and_then(Value::as_str)
            .filter(|value| safe_identifier(value, 40))
            .map(str::to_owned);
        let turns = object
            .get("turns")?
            .as_array()?
            .iter()
            .filter_map(|value| {
                let value = value.as_object()?;
                Some(UsageTurn {
                    number: value.get("turnNumber")?.as_u64()?,
                    ended_at: parse_date(value.get("endedAt")),
                    output_tokens: value.get("outputTokens").and_then(Value::as_i64),
                    reasoning_tokens: value.get("reasoningTokens").and_then(Value::as_i64),
                    incomplete: value.get("usageIsIncomplete").and_then(Value::as_bool),
                    model_usage: value.get("modelUsage").cloned(),
                })
            })
            .collect();
        Some(Self {
            session_id,
            updated_at,
            client_version,
            turns,
        })
    }
}

struct UsageReader {
    path: PathBuf,
    identity: Option<FileIdentity>,
    observed_len: Option<u64>,
    observed_modified: Option<std::time::SystemTime>,
    pending: Vec<u8>,
    refreshing: bool,
    snapshot_hash: Option<[u8; 32]>,
    snapshot: Option<UsageSnapshot>,
    bytes_read_last_poll: usize,
}

impl UsageReader {
    fn new(path: PathBuf) -> Self {
        Self {
            identity: None,
            path,
            observed_len: None,
            observed_modified: None,
            pending: Vec::new(),
            refreshing: false,
            snapshot_hash: None,
            snapshot: None,
            bytes_read_last_poll: 0,
        }
    }

    fn poll(&mut self, budget: usize) -> io::Result<()> {
        self.bytes_read_last_poll = 0;
        if budget == 0 {
            return Ok(());
        }
        let mut file = File::open(&self.path)?;
        let metadata = file.metadata()?;
        if metadata.len() > MAX_USAGE_BYTES {
            self.pending.clear();
            self.refreshing = false;
            self.snapshot_hash = None;
            self.snapshot = None;
            self.identity = file_identity(&metadata);
            self.observed_len = Some(metadata.len());
            self.observed_modified = metadata.modified().ok();
            return Ok(());
        }
        let identity = file_identity(&metadata);
        let modified = metadata.modified().ok();
        let changed = self.identity != identity
            || self.observed_len != Some(metadata.len())
            || self.observed_modified != modified;
        if changed {
            self.pending.clear();
            self.refreshing = false;
            self.identity = identity.clone();
            self.observed_len = Some(metadata.len());
            self.observed_modified = modified;
        } else if self.pending.is_empty() {
            // File timestamps are coarse on some supported filesystems and can
            // remain unchanged when Grok rewrites usage.json in place. Once a
            // snapshot exists, rescan it incrementally under the same per-file
            // budget and compare its digest instead of trusting metadata alone.
            self.refreshing = self.snapshot.is_some();
        }
        let remaining = metadata.len().saturating_sub(self.pending.len() as u64);
        if remaining == 0 {
            return Ok(());
        }
        let count = remaining.min(budget as u64) as usize;
        file.seek(SeekFrom::Start(self.pending.len() as u64))?;
        let mut bytes = vec![0; count];
        let mut total = 0;
        while total < count {
            let amount = file.read(&mut bytes[total..])?;
            if amount == 0 {
                break;
            }
            total += amount;
        }
        bytes.truncate(total);
        self.pending.extend_from_slice(&bytes);
        self.bytes_read_last_poll = total;
        if self.pending.len() as u64 == metadata.len() {
            // Avoid accepting a mixed read if the writer changed the file while
            // it was being scanned. Metadata remains useful here even though it
            // cannot be the sole freshness signal.
            let after = file.metadata()?;
            if after.len() != metadata.len()
                || file_identity(&after) != identity
                || after.modified().ok() != modified
            {
                self.pending.clear();
                self.refreshing = false;
                self.identity = file_identity(&after);
                self.observed_len = Some(after.len());
                self.observed_modified = after.modified().ok();
                return Ok(());
            }

            let digest: [u8; 32] = Sha256::digest(&self.pending).into();
            if !self.refreshing || self.snapshot_hash != Some(digest) {
                if let Some(snapshot) = UsageSnapshot::parse(&self.pending) {
                    self.snapshot = Some(snapshot);
                    self.snapshot_hash = Some(digest);
                }
            }
            // If parsing failed during a concurrent/incomplete write, retain the
            // last valid snapshot and try another bounded scan on the next poll.
            self.pending.clear();
            self.refreshing = false;
        }
        Ok(())
    }
}

struct GrokSession {
    key: String,
    events: EventReader,
    usage: UsageReader,
    last_emitted: HashMap<String, TurnMetric>,
}

impl GrokSession {
    fn new(candidate: &Candidate) -> Self {
        Self {
            key: candidate.key.clone(),
            events: EventReader::new(candidate.events_path.clone()),
            usage: UsageReader::new(candidate.usage_path.clone()),
            last_emitted: HashMap::new(),
        }
    }

    fn metrics(&mut self) -> Vec<TurnMetric> {
        let Some(snapshot) = self.usage.snapshot.as_ref() else {
            return Vec::new();
        };
        let mut counts = HashMap::<u64, usize>::new();
        for row in &snapshot.turns {
            *counts.entry(row.number).or_default() += 1;
        }
        let mut records = Vec::new();
        for turn in self.events.state.completed.iter().filter(|turn| turn.valid) {
            if snapshot.session_id.as_deref() != Some(turn.session_id.as_str())
                || counts.get(&turn.number) != Some(&1)
                || turn.number == 0
            {
                continue;
            }
            let Some(row) = snapshot.turns.iter().find(|row| row.number == turn.number) else {
                continue;
            };
            let Some(ended_at) = row.ended_at else {
                continue;
            };
            if ended_at < turn.completed_at - Duration::seconds(1)
                || ended_at > turn.completed_at + Duration::seconds(60)
                || turn
                    .next_primary_started_at
                    .is_some_and(|next_start| ended_at > next_start)
                || ended_at > snapshot.updated_at + Duration::seconds(1)
                || row.incomplete != Some(false)
            {
                continue;
            }
            let Some(output_tokens) = row
                .output_tokens
                .filter(|value| (0..=10_000_000).contains(value))
            else {
                continue;
            };
            let duration = (turn.completed_at - turn.started_at)
                .num_nanoseconds()
                .unwrap_or(0) as f64
                / 1e9;
            if !duration.is_finite() || duration <= 0.0 || duration > 86_400.0 {
                continue;
            }
            let id = digest_id(&self.key, turn.number, turn.completed_at);
            let model = single_model_key(row.model_usage.as_ref());
            let reasoning_tokens = row
                .reasoning_tokens
                .filter(|value| (0..=output_tokens).contains(value));
            let metric = TurnMetric::new_observed(
                id.clone(),
                turn.completed_at,
                model,
                output_tokens,
                duration,
                snapshot.client_version.clone(),
                reasoning_tokens,
                Some("primary".to_owned()),
                Some("unknown".to_owned()),
                None,
                GROK_CLIENT,
                GROK_PARSER_VERSION,
                GROK_METRIC_VERSION,
            );
            // A turn becomes immutable when first accepted. A later usage.json
            // rewrite must not create a second contribution with the same ID;
            // this matches the Swift monitor and backend's first-write dedupe.
            if !self.last_emitted.contains_key(&id) {
                self.last_emitted.insert(id, metric.clone());
                records.push(metric);
            }
        }
        records
    }
}

/// Bounded reader for Grok Build session event logs and usage snapshots.
pub struct GrokMonitor {
    root: PathBuf,
    sessions: HashMap<String, GrokSession>,
    last_discovery: Option<DateTime<Utc>>,
    next_session_index: usize,
    bytes_read_last_poll: usize,
}

impl GrokMonitor {
    pub const MAX_POLL_BYTES: usize = 1_048_576;

    pub fn new(root: PathBuf) -> Self {
        Self {
            root,
            sessions: HashMap::new(),
            last_discovery: None,
            next_session_index: 0,
            bytes_read_last_poll: 0,
        }
    }

    pub fn poll(&mut self, now: DateTime<Utc>) -> io::Result<Vec<TurnMetric>> {
        self.poll_with_budget(now, Self::MAX_POLL_BYTES)
    }

    pub fn poll_with_budget(
        &mut self,
        now: DateTime<Utc>,
        max_bytes: usize,
    ) -> io::Result<Vec<TurnMetric>> {
        self.bytes_read_last_poll = 0;
        if self.last_discovery.map_or(true, |last| {
            now < last || now - last >= Duration::seconds(10)
        }) || self.sessions.is_empty()
        {
            self.discover(now)?;
            self.last_discovery = Some(now);
        }
        if self.sessions.is_empty() || max_bytes == 0 {
            return Ok(Vec::new());
        }
        let mut sessions: Vec<String> = self.sessions.keys().cloned().collect();
        sessions.sort();
        let count = MAX_SESSIONS_PER_POLL.min(sessions.len());
        let mut budget = max_bytes.min(Self::MAX_POLL_BYTES);
        let mut records = Vec::new();
        for step in 0..count {
            if budget == 0 {
                break;
            }
            let key = &sessions[(self.next_session_index + step) % sessions.len()];
            let Some(session) = self.sessions.get_mut(key) else {
                continue;
            };
            let per_file = PER_FILE_BUDGET.min(budget);
            let event_budget = per_file.min(per_file / 2);
            if let Ok(()) = session.events.poll(event_budget) {
                let consumed = session.events.bytes_read_last_poll;
                budget = budget.saturating_sub(consumed);
                self.bytes_read_last_poll += consumed;
            }
            let usage_budget = PER_FILE_BUDGET.min(budget);
            if let Ok(()) = session.usage.poll(usage_budget) {
                let consumed = session.usage.bytes_read_last_poll;
                budget = budget.saturating_sub(consumed);
                self.bytes_read_last_poll += consumed;
            }
            records.extend(session.metrics());
        }
        self.next_session_index = (self.next_session_index + count) % sessions.len();
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

    fn discover(&mut self, now: DateTime<Utc>) -> io::Result<()> {
        let cutoff = now - Duration::days(7);
        let candidates = discover_candidates(&self.root, cutoff)?;
        let mut seen = HashSet::new();
        for candidate in candidates.into_iter().take(MAX_SESSIONS) {
            seen.insert(candidate.key.clone());
            self.sessions
                .entry(candidate.key.clone())
                .or_insert_with(|| GrokSession::new(&candidate));
        }
        self.sessions.retain(|key, _| seen.contains(key));
        Ok(())
    }
}

fn discover_candidates(root: &Path, cutoff: DateTime<Utc>) -> io::Result<Vec<Candidate>> {
    let entries = fs::read_dir(root)?;
    let mut candidates = Vec::new();
    for (index, entry) in entries.enumerate() {
        if index >= MAX_DISCOVERED_PATHS {
            break;
        }
        let Ok(entry) = entry else { continue };
        let name = entry.file_name();
        if name.to_string_lossy().starts_with('.')
            || !entry.file_type().is_ok_and(|kind| kind.is_dir())
        {
            continue;
        }
        let directory = entry.path();
        let events_path = directory.join("events.jsonl");
        let usage_path = directory.join("usage.json");
        let Ok(events_meta) = fs::metadata(&events_path) else {
            continue;
        };
        let Ok(usage_meta) = fs::metadata(&usage_path) else {
            continue;
        };
        if !events_meta.is_file() || !usage_meta.is_file() {
            continue;
        }
        let modified_at = [events_meta.modified().ok(), usage_meta.modified().ok()]
            .into_iter()
            .flatten()
            .max()
            .map(DateTime::<Utc>::from)
            .unwrap_or_else(Utc::now);
        if modified_at < cutoff {
            continue;
        }
        let key = directory.to_string_lossy().into_owned();
        candidates.push(Candidate {
            key,
            events_path,
            usage_path,
            modified_at,
        });
    }
    candidates.sort_by(|left, right| {
        right
            .modified_at
            .cmp(&left.modified_at)
            .then_with(|| left.key.cmp(&right.key))
    });
    Ok(candidates)
}

fn single_model_key(value: Option<&Value>) -> Option<String> {
    let object = value?.as_object()?;
    let mut keys = object.keys().filter(|key| !key.trim().is_empty());
    let model = keys.next()?;
    if keys.next().is_some() || !safe_identifier(model, 80) {
        return None;
    }
    Some(model.clone())
}

fn parse_date(value: Option<&Value>) -> Option<DateTime<Utc>> {
    let value = value?.as_str()?;
    DateTime::parse_from_rfc3339(value)
        .ok()
        .map(|date| date.with_timezone(&Utc))
}

fn safe_identifier(value: &str, maximum: usize) -> bool {
    !value.is_empty()
        && value.len() <= maximum
        && value
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'.' | b'_' | b'-' | b'+'))
}

fn digest_id(key: &str, number: u64, completed_at: DateTime<Utc>) -> String {
    let mut digest = Sha256::new();
    digest.update(key.as_bytes());
    digest.update(b"|");
    digest.update(number.to_be_bytes());
    digest.update(b"|");
    digest.update(completed_at.timestamp_millis().to_be_bytes());
    format!("{:x}", digest.finalize())
}
