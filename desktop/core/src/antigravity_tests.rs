//! Tests for the protobuf reader, the Antigravity database reader, the execution/turn builder
//! and the monitor, over synthetic SQLite databases with hand-encoded protobuf blobs.

use crate::antigravity_db::{read_database, GenerationCache};
use crate::antigravity_turns::turn_id;
use crate::monitor::SourceChange;
use crate::protobuf::{Malformed, Message};
use crate::sqlite_read::read_only_uri;
use crate::{
    AntigravityMonitor, ProviderBadge, SharedSample, SourceMonitor, ToolSurface, TurnMetric,
    ANTIGRAVITY_CLIENT, ANTIGRAVITY_METRIC_VERSION, ANTIGRAVITY_PARSER_VERSION,
};
use chrono::{DateTime, Duration, SubsecRound, Utc};
use rusqlite::{params, Connection};
use sha2::{Digest, Sha256};
use std::fs::{self, File, FileTimes};
use std::path::{Path, PathBuf};
use std::time::SystemTime;
use tempfile::TempDir;
use uuid::Uuid;

// ---- a tiny protobuf encoder -------------------------------------------------------------

#[derive(Default)]
struct Pb(Vec<u8>);

fn push_varint(out: &mut Vec<u8>, mut value: u64) {
    loop {
        let byte = (value & 0x7f) as u8;
        value >>= 7;
        if value == 0 {
            out.push(byte);
            return;
        }
        out.push(byte | 0x80);
    }
}

impl Pb {
    fn tag(mut self, number: u32, wire: u8) -> Self {
        push_varint(&mut self.0, u64::from(number) << 3 | u64::from(wire));
        self
    }

    fn varint(mut self, number: u32, value: u64) -> Self {
        self = self.tag(number, 0);
        push_varint(&mut self.0, value);
        self
    }

    /// proto3 omits zero values.
    fn varint_nonzero(self, number: u32, value: u64) -> Self {
        if value == 0 {
            self
        } else {
            self.varint(number, value)
        }
    }

    fn bytes(mut self, number: u32, value: &[u8]) -> Self {
        self = self.tag(number, 2);
        push_varint(&mut self.0, value.len() as u64);
        self.0.extend_from_slice(value);
        self
    }

    fn string(self, number: u32, value: &str) -> Self {
        self.bytes(number, value.as_bytes())
    }

    fn message(self, number: u32, value: Pb) -> Self {
        self.bytes(number, &value.0)
    }

    fn fixed32(mut self, number: u32, value: u32) -> Self {
        self = self.tag(number, 5);
        self.0.extend_from_slice(&value.to_le_bytes());
        self
    }

    fn fixed64(mut self, number: u32, value: u64) -> Self {
        self = self.tag(number, 1);
        self.0.extend_from_slice(&value.to_le_bytes());
        self
    }

    fn raw(mut self, bytes: &[u8]) -> Self {
        self.0.extend_from_slice(bytes);
        self
    }

    fn done(self) -> Vec<u8> {
        self.0
    }
}

fn stamp(at: DateTime<Utc>) -> Pb {
    Pb::default()
        .varint(1, at.timestamp() as u64)
        .varint_nonzero(2, u64::from(at.timestamp_subsec_nanos()))
}

// ---- synthetic databases -------------------------------------------------------------------

const EXECUTION: &str = "7713a1b5-0000-4000-8000-000000000001";
const CONVERSATION: &str = "82f9b30f-0000-4000-8000-000000000002";
const MODEL: &str = "gemini-3.8-flash";

#[derive(Clone)]
struct StepSpec {
    idx: i64,
    execution: Option<String>,
    created: Option<DateTime<Utc>>,
    completed: Option<DateTime<Utc>>,
    /// (output tokens, thinking tokens)
    usage: Option<(u64, u64)>,
    generation: u64,
    /// (uncached input tokens 9.2, cache-read tokens 9.5)
    input: (u64, u64),
    omit_generation_message: bool,
    subtrajectory: bool,
}

impl StepSpec {
    fn new(idx: i64, execution: &str) -> Self {
        Self {
            idx,
            execution: Some(execution.to_owned()),
            created: None,
            completed: None,
            usage: None,
            generation: 0,
            input: (5_000, 4_000),
            omit_generation_message: false,
            subtrajectory: false,
        }
    }

    fn span(mut self, created: DateTime<Utc>, completed: DateTime<Utc>) -> Self {
        self.created = Some(created);
        self.completed = Some(completed);
        self
    }

    fn created(mut self, created: DateTime<Utc>) -> Self {
        self.created = Some(created);
        self
    }

    fn usage(mut self, output: u64, thinking: u64) -> Self {
        self.usage = Some((output, thinking));
        self
    }

    fn input(mut self, uncached: u64, cache_read: u64) -> Self {
        self.input = (uncached, cache_read);
        self
    }

    fn generation(mut self, generation: u64) -> Self {
        self.generation = generation;
        self
    }

    fn subtrajectory(mut self) -> Self {
        self.subtrajectory = true;
        self
    }

    fn blob(&self) -> Vec<u8> {
        let mut pb = Pb::default();
        if let Some(created) = self.created {
            pb = pb.message(1, stamp(created));
        }
        if let Some(completed) = self.completed {
            pb = pb.message(7, stamp(completed));
        }
        if let Some((output, thinking)) = self.usage {
            pb = pb.message(
                9,
                Pb::default()
                    .varint_nonzero(2, self.input.0)
                    .varint_nonzero(3, output)
                    .varint_nonzero(5, self.input.1)
                    .varint_nonzero(9, thinking),
            );
        }
        if let Some(execution) = &self.execution {
            pb = pb.string(12, execution);
        }
        if !self.omit_generation_message {
            pb = pb.message(
                20,
                Pb::default()
                    .string(1, "not-read")
                    .varint_nonzero(3, self.generation),
            );
        }
        pb.done()
    }
}

fn executor_blob(state: u64, id: &str, variant: Option<&str>) -> Vec<u8> {
    let mut pb = Pb::default().varint_nonzero(1, state).string(9, id);
    if let Some(variant) = variant {
        pb = pb.message(
            10,
            Pb::default().message(1, Pb::default().string(28, variant)),
        );
    }
    pb.done()
}

/// A generation row padded with an unrelated field, as the real ones carry megabytes of context.
fn padded_generation_blob(model: &str, padding: usize) -> Vec<u8> {
    let mut blob = generation_blob(model, Some("false"));
    blob.extend(Pb::default().bytes(99, &vec![b'x'; padding]).done());
    blob
}

fn generation_blob(model: &str, non_gemini: Option<&str>) -> Vec<u8> {
    let mut inner = Pb::default().varint(3, 1318).string(19, model).message(
        20,
        Pb::default()
            .string(1, "used_claude")
            .string(2, "confidential-value"),
    );
    if let Some(value) = non_gemini {
        inner = inner.message(
            20,
            Pb::default()
                .string(1, "used_non_gemini_model")
                .string(2, value),
        );
    }
    Pb::default()
        .message(2, Pb::default())
        .message(1, inner)
        .done()
}

struct Database {
    path: PathBuf,
    connection: Connection,
}

impl Database {
    fn create(path: PathBuf) -> Self {
        fs::create_dir_all(path.parent().unwrap()).unwrap();
        let connection = Connection::open(&path).unwrap();
        connection
            .execute_batch(
                "CREATE TABLE trajectory_meta (trajectory_id text, cascade_id text, trajectory_type integer, source integer, PRIMARY KEY (trajectory_id));
                 CREATE TABLE steps (idx integer, step_type integer NOT NULL DEFAULT 0, status integer NOT NULL DEFAULT 0, has_subtrajectory numeric NOT NULL DEFAULT false, metadata blob, error_details blob, permissions blob, task_details blob, render_info blob, step_payload blob, PRIMARY KEY (idx));
                 CREATE TABLE gen_metadata (idx integer, data blob, size integer NOT NULL DEFAULT 0, PRIMARY KEY (idx));
                 CREATE TABLE executor_metadata (idx integer, data blob, PRIMARY KEY (idx));
                 CREATE TABLE parent_references (idx integer, data blob, PRIMARY KEY (idx));
                 CREATE TABLE trajectory_metadata_blob (id text DEFAULT 'main', data blob, PRIMARY KEY (id));
                 CREATE TABLE battle_mode_infos (idx integer, data blob, PRIMARY KEY (idx));",
            )
            .unwrap();
        // Content the reader must never select.
        connection
            .execute(
                "INSERT INTO trajectory_metadata_blob (id, data) VALUES ('main', x'ffffffff')",
                [],
            )
            .unwrap();
        Self { path, connection }
    }

    fn step(&self, spec: &StepSpec) {
        self.raw_step(spec.idx, spec.subtrajectory, Some(spec.blob()));
    }

    fn raw_step(&self, idx: i64, subtrajectory: bool, metadata: Option<Vec<u8>>) {
        self.connection
            .execute(
                "INSERT OR REPLACE INTO steps (idx, has_subtrajectory, metadata, step_payload) VALUES (?1, ?2, ?3, x'deadbeef')",
                params![idx, subtrajectory, metadata],
            )
            .unwrap();
    }

    fn executor(&self, idx: i64, blob: &[u8]) {
        self.connection
            .execute(
                "INSERT OR REPLACE INTO executor_metadata (idx, data) VALUES (?1, ?2)",
                params![idx, blob],
            )
            .unwrap();
    }

    fn generation(&self, idx: i64, blob: &[u8]) {
        self.connection
            .execute(
                "INSERT OR REPLACE INTO gen_metadata (idx, data, size) VALUES (?1, ?2, ?3)",
                params![idx, blob, blob.len() as i64],
            )
            .unwrap();
    }

    fn parent_reference(&self) {
        self.connection
            .execute(
                "INSERT INTO parent_references (idx, data) VALUES (0, x'0a00')",
                [],
            )
            .unwrap();
    }
}

struct Fixture {
    dir: TempDir,
}

impl Fixture {
    fn new() -> Self {
        Self {
            dir: tempfile::tempdir().unwrap(),
        }
    }

    fn root(&self) -> PathBuf {
        self.dir.path().join(".gemini")
    }

    fn database(&self, folder: &str, id: &str) -> Database {
        Database::create(
            self.root()
                .join(folder)
                .join("conversations")
                .join(format!("{id}.db")),
        )
    }

    fn primary(&self) -> Database {
        self.database("antigravity", CONVERSATION)
    }

    fn monitor(&self) -> AntigravityMonitor {
        AntigravityMonitor::new(self.root())
    }
}

fn now() -> DateTime<Utc> {
    Utc::now().trunc_subsecs(0)
}

fn sha256_hex(text: &str) -> String {
    format!("{:x}", Sha256::digest(text.as_bytes()))
}

/// A finished execution: a user step, three model calls (two qualifying responses and one
/// short one) and a tool step. Starts at `t0`, ends 30 s later.
fn finished_execution(db: &Database, t0: DateTime<Utc>, state: u64) {
    let seconds = |value: i64| t0 + Duration::seconds(value);
    db.generation(0, &generation_blob(MODEL, Some("false")));
    db.executor(
        0,
        &executor_blob(state, EXECUTION, Some("gemini-3.8-flash-medium")),
    );
    db.step(&StepSpec::new(0, EXECUTION).created(seconds(0)));
    let mut first = StepSpec::new(1, EXECUTION)
        .span(seconds(1), seconds(11))
        .usage(1_000, 300);
    // No 20 message at all: generation 0.
    first.omit_generation_message = true;
    db.step(&first);
    db.step(&StepSpec::new(2, EXECUTION).span(seconds(11), seconds(15)));
    db.step(
        &StepSpec::new(3, EXECUTION)
            .span(seconds(16), seconds(26))
            .usage(500, 100),
    );
    db.step(
        &StepSpec::new(4, EXECUTION)
            .span(seconds(27), seconds(30))
            .usage(150, 0),
    );
}

fn poll(monitor: &mut AntigravityMonitor, at: DateTime<Utc>) -> Vec<TurnMetric> {
    monitor.poll(at).unwrap()
}

// ---- protobuf --------------------------------------------------------------------------------

#[test]
fn protobuf_reads_every_wire_type_nested_messages_and_repeated_fields() {
    let blob = Pb::default()
        .varint(1, 300)
        .fixed64(2, 0x0102_0304_0506_0708)
        .string(3, "héllo")
        .fixed32(4, 7)
        .message(5, Pb::default().varint(1, 9).string(2, "inner"))
        .message(6, Pb::default().string(1, "a"))
        .message(6, Pb::default().string(1, "b"))
        .varint(1, 301)
        .done();
    let message = Message::parse(&blob).unwrap();
    // The last occurrence of a singular field wins.
    assert_eq!(message.varint(1), Ok(Some(301)));
    assert_eq!(message.varint(99), Ok(None));
    assert_eq!(message.string(3), Ok(Some("héllo")));
    let inner = message.message(5).unwrap().unwrap();
    assert_eq!(inner.varint(1), Ok(Some(9)));
    assert_eq!(inner.string(2), Ok(Some("inner")));
    let repeated = message.messages(6).unwrap();
    assert_eq!(repeated.len(), 2);
    assert_eq!(repeated[1].string(1), Ok(Some("b")));
    assert!(matches!(message.messages(99), Ok(list) if list.is_empty()));
    // A present field with another wire type is malformed, not absent.
    assert_eq!(message.varint(3), Err(Malformed));
    assert!(message.message(1).is_err());
    assert_eq!(message.string(1), Err(Malformed));
    assert!(message.message(4).is_err());
    assert!(Message::parse(&[]).is_some());
}

#[test]
fn protobuf_rejects_truncated_grouped_reserved_and_overlong_input() {
    // Truncated varint, fixed32, fixed64 and length-delimited values.
    assert!(Message::parse(&[0x08, 0x80]).is_none());
    assert!(Message::parse(&Pb::default().tag(1, 5).raw(&[1, 2, 3]).done()).is_none());
    assert!(Message::parse(&Pb::default().tag(1, 1).raw(&[1; 7]).done()).is_none());
    assert!(Message::parse(&Pb::default().tag(1, 2).raw(&[5, b'a']).done()).is_none());
    // Groups and the reserved wire types 6 and 7.
    for wire in [3, 4, 6, 7] {
        assert!(Message::parse(&Pb::default().tag(1, wire).done()).is_none());
    }
    // Field number zero and a number above 2^29 - 1.
    assert!(Message::parse(&[0x00, 0x01]).is_none());
    let mut large = Vec::new();
    push_varint(&mut large, (1u64 << 29) << 3);
    large.push(0);
    assert!(Message::parse(&large).is_none());
    // A length that does not fit the remaining bytes, even when huge.
    let mut huge = vec![0x0a];
    push_varint(&mut huge, u64::MAX);
    assert!(Message::parse(&huge).is_none());
    // A varint of eleven bytes, and a tenth byte that overflows 64 bits.
    assert!(Message::parse(&[
        0x08, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x01
    ])
    .is_none());
    assert!(
        Message::parse(&[0x08, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x02])
            .is_none()
    );
    let max = Message::parse(&[
        0x08, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x01,
    ])
    .unwrap();
    assert_eq!(max.varint(1), Ok(Some(u64::MAX)));
    // Invalid UTF-8 in a string and a malformed nested message are malformed values.
    let blob = Pb::default().bytes(1, &[0xff, 0xfe]).done();
    let message = Message::parse(&blob).unwrap();
    assert_eq!(message.string(1), Err(Malformed));
    assert!(message.message(1).is_err());
}

// ---- database access -------------------------------------------------------------------------

#[test]
fn database_uri_is_percent_encoded_read_only_and_never_immutable() {
    let uri = |path: &str| read_only_uri(Path::new(path)).unwrap();
    assert_eq!(
        uri("/home/user/.gemini/antigravity/conversations/a-b_c.d~e.db"),
        "file:///home/user/.gemini/antigravity/conversations/a-b_c.d~e.db?mode=ro"
    );
    assert_eq!(
        uri("/tmp/my folder/what? #1 100%.db"),
        "file:///tmp/my%20folder/what%3F%20%231%20100%25.db?mode=ro"
    );
    assert_eq!(uri("/tmp/é.db"), "file:///tmp/%C3%A9.db?mode=ro");
    assert_eq!(
        uri(r"C:\Users\Jo Smith\.gemini\x.db"),
        "file:///C:/Users/Jo%20Smith/.gemini/x.db?mode=ro"
    );
    assert_eq!(
        uri(r"\\server\share\x.db"),
        "file:////server/share/x.db?mode=ro"
    );
    assert!(!uri("/tmp/x.db").contains("immutable"));
}

#[test]
fn reading_leaves_the_database_byte_identical_and_decodes_the_field_map() {
    let fixture = Fixture::new();
    let db = fixture.primary();
    let t0 = now() - Duration::seconds(120);
    finished_execution(&db, t0, 4);
    let before = fs::read(&db.path).unwrap();
    let modified = fs::metadata(&db.path).unwrap().modified().unwrap();

    let snapshot = read_database(&db.path, &mut GenerationCache::default()).unwrap();
    assert_eq!(snapshot.steps.len(), 5);
    assert!(!snapshot.is_subagent);
    assert_eq!(snapshot.executors.len(), 1);
    assert_eq!(snapshot.executors[0].state, 4);
    assert_eq!(
        snapshot.executors[0].variant.as_deref(),
        Some("gemini-3.8-flash-medium")
    );
    assert_eq!(snapshot.generations[&0].model.as_deref(), Some(MODEL));
    assert!(snapshot.generations[&0].gemini_only);
    let call = &snapshot.steps[1];
    assert_eq!(call.usage.unwrap().output_tokens, 1_000);
    assert_eq!(call.usage.unwrap().thinking_tokens, 300);
    assert_eq!(call.generation, 0);
    assert_eq!(call.created, Some(t0 + Duration::seconds(1)));
    assert!(snapshot.bytes_read > 0);

    drop(snapshot);
    assert_eq!(fs::read(&db.path).unwrap(), before);
    assert_eq!(
        fs::metadata(&db.path).unwrap().modified().unwrap(),
        modified
    );
}

#[test]
fn a_database_in_a_folder_with_spaces_is_read() {
    let fixture = Fixture::new();
    let db = Database::create(
        fixture
            .dir
            .path()
            .join("My Documents #1")
            .join("100% gemini data")
            .join(".gemini/antigravity/conversations")
            .join(format!("{CONVERSATION}.db")),
    );
    finished_execution(&db, now() - Duration::seconds(120), 4);
    assert_eq!(
        read_database(&db.path, &mut GenerationCache::default())
            .unwrap()
            .steps
            .len(),
        5
    );
    let mut monitor = AntigravityMonitor::new(
        fixture
            .dir
            .path()
            .join("My Documents #1")
            .join("100% gemini data")
            .join(".gemini"),
    );
    assert_eq!(poll(&mut monitor, now()).len(), 1);
}

#[test]
fn write_ahead_log_content_is_read_and_a_log_change_triggers_a_reread() {
    let fixture = Fixture::new();
    let db = fixture.primary();
    db.connection
        .pragma_update(None, "journal_mode", "WAL")
        .unwrap();
    db.connection
        .pragma_update(None, "wal_autocheckpoint", 0)
        .unwrap();
    let t0 = now() - Duration::seconds(120);
    finished_execution(&db, t0, 0);
    let mut monitor = fixture.monitor();
    assert!(poll(&mut monitor, now()).is_empty());
    assert!(monitor.bytes_read_last_poll() > 0);
    // Nothing changed: no read.
    assert!(poll(&mut monitor, now()).is_empty());
    assert_eq!(monitor.bytes_read_last_poll(), 0);

    // The state change lives only in the write-ahead log.
    db.executor(
        0,
        &executor_blob(4, EXECUTION, Some("gemini-3.8-flash-medium")),
    );
    assert!(
        fs::metadata(format!("{}-wal", db.path.display()))
            .unwrap()
            .len()
            > 0
    );
    let turns = poll(&mut monitor, now());
    assert_eq!(turns.len(), 1);
    assert!(monitor.bytes_read_last_poll() > 0);
}

// ---- turns -----------------------------------------------------------------------------------

#[test]
fn a_finished_execution_becomes_one_turn_with_exact_values() {
    let fixture = Fixture::new();
    let db = fixture.primary();
    let t0 = now() - Duration::seconds(120);
    finished_execution(&db, t0, 4);
    let mut monitor = fixture.monitor();
    let turns = poll(&mut monitor, now());
    assert_eq!(turns.len(), 1);
    let turn = &turns[0];
    assert_eq!(
        turn.id,
        sha256_hex(&format!("antigravity|{CONVERSATION}|{EXECUTION}"))
    );
    assert_eq!(turn.id, turn_id(CONVERSATION, EXECUTION));
    assert_eq!(turn.client, ANTIGRAVITY_CLIENT);
    assert_eq!(turn.parser_version, ANTIGRAVITY_PARSER_VERSION);
    assert_eq!(turn.metric_version, ANTIGRAVITY_METRIC_VERSION);
    assert_eq!(turn.source_kind.as_deref(), Some("primary"));
    assert_eq!(turn.model.as_deref(), Some(MODEL));
    assert_eq!(turn.reasoning_effort.as_deref(), Some("medium"));
    assert_eq!(turn.provider.as_deref(), Some("google"));
    assert_eq!(turn.output_tokens, 1_650);
    assert_eq!(turn.reasoning_output_tokens, Some(400));
    assert_eq!(turn.duration_seconds, 30.0);
    assert_eq!(turn.turn_throughput_tps, 55.0);
    assert_eq!(turn.completed_at, t0 + Duration::seconds(30));
    assert_eq!(turn.client_version, None);
    assert_eq!(turn.codex_ttft_seconds, None);
    assert_eq!(turn.provider_region, None);
    // Two model calls qualify as responses; the 150-token one does not.
    assert_eq!(turn.response_output_tokens, Some(1_500));
    assert_eq!(turn.response_duration_seconds, Some(20.0));
    assert_eq!(turn.response_count, Some(2));
    assert_eq!(turn.delegated_output_tokens, Some(0));
    assert_eq!(turn.surface, Some(ToolSurface::Desktop));
    // Three model calls of 5,000 uncached and 4,000 cache-read input tokens each; the input total
    // includes the cached tokens and cache writes are not recorded.
    assert_eq!(turn.input_tokens, Some(27_000));
    assert_eq!(turn.cache_read_input_tokens, Some(12_000));
    assert_eq!(turn.cache_write_input_tokens, None);
    // Each execution is emitted once.
    assert!(poll(&mut monitor, now()).is_empty());
}

#[test]
fn prompt_cache_sums_uncached_and_cache_read_input_with_absent_counts_as_zero() {
    let fixture = Fixture::new();
    let db = fixture.primary();
    let t0 = now() - Duration::seconds(120);
    let seconds = |value: i64| t0 + Duration::seconds(value);
    db.generation(0, &generation_blob(MODEL, Some("false")));
    db.executor(0, &executor_blob(4, EXECUTION, None));
    db.step(
        &StepSpec::new(0, EXECUTION)
            .span(seconds(0), seconds(10))
            .usage(300, 0)
            .input(1_000, 0),
    );
    // Nothing read from the cache and no uncached input: both counts absent, i.e. 0.
    db.step(
        &StepSpec::new(1, EXECUTION)
            .span(seconds(10), seconds(20))
            .usage(300, 0)
            .input(0, 0),
    );
    db.step(
        &StepSpec::new(2, EXECUTION)
            .span(seconds(20), seconds(30))
            .usage(300, 0)
            .input(200, 3_000),
    );
    let turn = &poll(&mut fixture.monitor(), now())[0];
    assert_eq!(turn.input_tokens, Some(1_000 + 200 + 3_000));
    assert_eq!(turn.cache_read_input_tokens, Some(3_000));
    assert_eq!(turn.cache_write_input_tokens, None);
    // The shared sample carries the same consistent set (cache write explicitly null).
    let sample = SharedSample::from_metric(turn, Uuid::new_v4()).unwrap();
    assert_eq!(
        (
            sample.input_tokens,
            sample.cache_read_input_tokens,
            sample.cache_write_input_tokens
        ),
        (Some(4_200), Some(3_000), None)
    );
    let json = serde_json::to_value(&sample).unwrap();
    assert!(json["cacheWriteInputTokens"].is_null());
    assert_eq!(json["inputTokens"], 4_200);
}

#[test]
fn known_generations_are_not_fetched_again_and_a_row_written_later_is_picked_up() {
    let fixture = Fixture::new();
    let db = fixture.primary();
    let started = now();
    let s = started - Duration::seconds(0);
    db.executor(
        0,
        &executor_blob(0, EXECUTION, Some("gemini-3.8-flash-high")),
    );
    db.generation(0, &padded_generation_blob(MODEL, 30_000));
    // Generation 1 exists but cannot be decoded; generation 2 is not written yet.
    let mut garbage = vec![0x0a, 0x7f];
    garbage.extend(vec![0u8; 20_000]);
    db.generation(1, &garbage);
    let call = |idx: i64, generation: u64, at: i64| {
        StepSpec::new(idx, EXECUTION)
            .span(s + Duration::seconds(at), s + Duration::seconds(at + 10))
            .usage(500, 0)
            .generation(generation)
    };
    db.step(&call(0, 0, 1));
    db.step(&call(1, 1, 12));
    db.step(&call(2, 2, 24));
    let mut monitor = fixture.monitor();
    poll(&mut monitor, started - Duration::seconds(1));
    // The first read fetched both rows that exist: the 30 KB and the 20 KB one.
    assert!(monitor.bytes_read_last_poll() >= 50_000);
    monitor.take_live_responses();

    // A later change re-reads steps but none of the known generation rows, readable or not.
    db.step(&call(3, 0, 36));
    poll(&mut monitor, started + Duration::seconds(50));
    let bytes = monitor.bytes_read_last_poll();
    assert!(bytes > 0 && bytes < 20_000, "{bytes}");
    // Its model call is still attributed from the cache; the call of the absent row is not.
    let live = monitor.take_live_responses();
    assert_eq!(live.len(), 1);
    assert_eq!(live[0].model.as_deref(), Some(MODEL));

    // The absent row is written later: asked for again, decoded once and picked up.
    db.generation(2, &padded_generation_blob("gemini-3.8-pro", 5_000));
    db.step(&call(4, 2, 48));
    poll(&mut monitor, started + Duration::seconds(70));
    let live = monitor.take_live_responses();
    assert_eq!(
        live.iter()
            .filter_map(|r| r.model.as_deref())
            .collect::<Vec<_>>(),
        ["gemini-3.8-pro", "gemini-3.8-pro"],
        "the earlier call that waited for its row and the new one"
    );
    let bytes = monitor.bytes_read_last_poll();
    assert!(bytes >= 5_000 && bytes < 20_000, "{bytes}");
    // The unreadable row stays unfetched.
    db.step(&call(5, 1, 60));
    poll(&mut monitor, started + Duration::seconds(80));
    assert!(monitor.bytes_read_last_poll() < 5_000);
    assert!(monitor.take_live_responses().is_empty());
}

#[test]
fn an_unfinished_execution_is_emitted_exactly_once_after_it_becomes_finished() {
    let fixture = Fixture::new();
    let db = fixture.primary();
    let t0 = now() - Duration::seconds(120);
    finished_execution(&db, t0, 0);
    let mut monitor = fixture.monitor();
    assert!(poll(&mut monitor, now()).is_empty());
    for state in [1, 2, 3, 5] {
        db.executor(
            0,
            &executor_blob(state, EXECUTION, Some("gemini-3.8-flash-medium")),
        );
        assert!(poll(&mut monitor, now()).is_empty(), "state {state}");
    }
    db.executor(
        0,
        &executor_blob(4, EXECUTION, Some("gemini-3.8-flash-medium")),
    );
    assert_eq!(poll(&mut monitor, now()).len(), 1);
    // Further activity in the same conversation never re-emits it.
    db.step(&StepSpec::new(9, "later-execution").created(t0));
    assert!(poll(&mut monitor, now()).is_empty());
    db.executor(
        0,
        &executor_blob(4, EXECUTION, Some("gemini-3.8-flash-medium")),
    );
    assert!(poll(&mut monitor, now()).is_empty());
}

#[test]
fn an_absent_execution_state_is_zero_and_never_emitted() {
    let fixture = Fixture::new();
    let db = fixture.primary();
    finished_execution(&db, now() - Duration::seconds(120), 0);
    assert!(poll(&mut fixture.monitor(), now()).is_empty());
}

#[test]
fn mixed_models_leave_model_effort_and_provider_unknown() {
    let fixture = Fixture::new();
    let db = fixture.primary();
    let t0 = now() - Duration::seconds(120);
    finished_execution(&db, t0, 4);
    db.generation(7, &generation_blob("gemini-3.8-pro", Some("false")));
    db.step(
        &StepSpec::new(5, EXECUTION)
            .span(t0 + Duration::seconds(30), t0 + Duration::seconds(40))
            .usage(300, 0)
            .generation(7),
    );
    let turn = &poll(&mut fixture.monitor(), now())[0];
    assert_eq!(turn.model, None);
    assert_eq!(turn.reasoning_effort, None);
    assert_eq!(turn.provider.as_deref(), Some("unknown"));
    assert_eq!(turn.output_tokens, 1_950);
}

#[test]
fn a_call_without_a_generation_row_leaves_the_model_unknown() {
    let fixture = Fixture::new();
    let db = fixture.primary();
    let t0 = now() - Duration::seconds(120);
    finished_execution(&db, t0, 4);
    db.step(
        &StepSpec::new(5, EXECUTION)
            .span(t0 + Duration::seconds(30), t0 + Duration::seconds(40))
            .usage(300, 0)
            .generation(99),
    );
    let turn = &poll(&mut fixture.monitor(), now())[0];
    assert_eq!(turn.model, None);
    assert_eq!(turn.provider.as_deref(), Some("unknown"));
}

#[test]
fn non_gemini_variants_have_unknown_effort_and_provider() {
    let fixture = Fixture::new();
    let db = fixture.primary();
    let t0 = now() - Duration::seconds(120);
    finished_execution(&db, t0, 4);
    db.generation(
        0,
        &generation_blob("claude-opus-4-6-thinking", Some("true")),
    );
    db.executor(
        0,
        &executor_blob(4, EXECUTION, Some("claude-opus-4-6-thinking")),
    );
    let turn = &poll(&mut fixture.monitor(), now())[0];
    assert_eq!(turn.model.as_deref(), Some("claude-opus-4-6-thinking"));
    assert_eq!(turn.reasoning_effort, None);
    assert_eq!(turn.provider.as_deref(), Some("unknown"));
}

#[test]
fn google_needs_a_gemini_model_and_a_false_non_gemini_flag_on_every_generation() {
    for (model, flag, provider) in [
        (MODEL, Some("false"), "google"),
        (MODEL, Some("true"), "unknown"),
        (MODEL, None, "unknown"),
        ("claude-opus-4-6-thinking", Some("false"), "unknown"),
    ] {
        let fixture = Fixture::new();
        let db = fixture.primary();
        finished_execution(&db, now() - Duration::seconds(120), 4);
        db.generation(0, &generation_blob(model, flag));
        let turn = &poll(&mut fixture.monitor(), now())[0];
        assert_eq!(turn.provider.as_deref(), Some(provider), "{model} {flag:?}");
    }
    // One generation of two says it used another model.
    let fixture = Fixture::new();
    let db = fixture.primary();
    let t0 = now() - Duration::seconds(120);
    finished_execution(&db, t0, 4);
    db.generation(1, &generation_blob(MODEL, Some("true")));
    db.step(
        &StepSpec::new(5, EXECUTION)
            .span(t0 + Duration::seconds(30), t0 + Duration::seconds(40))
            .usage(300, 0)
            .generation(1),
    );
    let turn = &poll(&mut fixture.monitor(), now())[0];
    assert_eq!(turn.model.as_deref(), Some(MODEL));
    assert_eq!(turn.provider.as_deref(), Some("unknown"));
}

#[test]
fn effort_comes_only_from_a_known_suffix_of_the_variant() {
    for (variant, effort) in [
        ("gemini-3.8-flash-minimal", Some("minimal")),
        ("gemini-3.8-flash-low", Some("low")),
        ("gemini-3.8-flash-medium", Some("medium")),
        ("gemini-3.8-flash-high", Some("high")),
        ("gemini-3.8-flash-xhigh", Some("xhigh")),
        ("gemini-3.8-flash-max", Some("max")),
        ("gemini-3.8-flash", None),
        ("gemini-3.8-flash-ultra", None),
        ("gemini-3.8-flash-", None),
        ("gemini-3.8-flashmedium", None),
        ("other-model-medium", None),
    ] {
        let fixture = Fixture::new();
        let db = fixture.primary();
        finished_execution(&db, now() - Duration::seconds(120), 4);
        db.executor(0, &executor_blob(4, EXECUTION, Some(variant)));
        let turn = &poll(&mut fixture.monitor(), now())[0];
        assert_eq!(turn.reasoning_effort.as_deref(), effort, "{variant}");
    }
    // No variant at all.
    let fixture = Fixture::new();
    let db = fixture.primary();
    finished_execution(&db, now() - Duration::seconds(120), 4);
    db.executor(0, &executor_blob(4, EXECUTION, None));
    assert_eq!(
        poll(&mut fixture.monitor(), now())[0].reasoning_effort,
        None
    );
}

#[test]
fn subagent_trajectories_are_not_measured() {
    let fixture = Fixture::new();
    let db = fixture.primary();
    finished_execution(&db, now() - Duration::seconds(120), 4);
    db.parent_reference();
    let mut monitor = fixture.monitor();
    assert!(poll(&mut monitor, now()).is_empty());
    assert!(monitor.take_live_responses().is_empty());
}

#[test]
fn started_subagent_work_leaves_delegated_output_unattributed() {
    let fixture = Fixture::new();
    let db = fixture.primary();
    let t0 = now() - Duration::seconds(120);
    finished_execution(&db, t0, 4);
    db.step(
        &StepSpec::new(2, EXECUTION)
            .span(t0 + Duration::seconds(11), t0 + Duration::seconds(15))
            .subtrajectory(),
    );
    let turn = &poll(&mut fixture.monitor(), now())[0];
    assert_eq!(turn.delegated_output_tokens, None);
    assert_eq!(turn.output_tokens, 1_650);
    // Never final, so never shared and never counted by the efficiency indicator.
    assert!(SharedSample::from_metric(turn, Uuid::new_v4()).is_none());
}

#[test]
fn only_qualifying_model_calls_count_as_responses() {
    let fixture = Fixture::new();
    let db = fixture.primary();
    let t0 = now() - Duration::seconds(2_000);
    let seconds = |value: i64| t0 + Duration::seconds(value);
    db.generation(0, &generation_blob(MODEL, Some("false")));
    db.executor(
        0,
        &executor_blob(4, EXECUTION, Some("gemini-3.8-flash-low")),
    );
    // 199 tokens (too short), 5,000 tokens over 700 s (too long), 500 tokens over 10 s.
    db.step(
        &StepSpec::new(0, EXECUTION)
            .span(seconds(0), seconds(10))
            .usage(199, 0),
    );
    db.step(
        &StepSpec::new(1, EXECUTION)
            .span(seconds(10), seconds(710))
            .usage(5_000, 0),
    );
    db.step(
        &StepSpec::new(2, EXECUTION)
            .span(seconds(710), seconds(720))
            .usage(500, 0),
    );
    let turn = &poll(&mut fixture.monitor(), now())[0];
    assert_eq!(turn.output_tokens, 5_699);
    assert_eq!(turn.response_count, Some(1));
    assert_eq!(turn.response_output_tokens, Some(500));
    assert_eq!(turn.response_duration_seconds, Some(10.0));

    // Nothing qualifies: the response fields are all absent.
    let other = Fixture::new();
    let db = other.primary();
    db.generation(0, &generation_blob(MODEL, Some("false")));
    db.executor(0, &executor_blob(4, EXECUTION, None));
    db.step(
        &StepSpec::new(0, EXECUTION)
            .span(seconds(0), seconds(10))
            .usage(100, 0),
    );
    let turn = &poll(&mut other.monitor(), now())[0];
    assert_eq!(
        (
            turn.response_output_tokens,
            turn.response_duration_seconds,
            turn.response_count
        ),
        (None, None, None)
    );
}

#[test]
fn an_implausibly_fast_or_instant_turn_makes_no_record() {
    let t0 = now() - Duration::seconds(120);
    for (output, seconds) in [(20_001u64, 10i64), (500, 0)] {
        let fixture = Fixture::new();
        let db = fixture.primary();
        db.generation(0, &generation_blob(MODEL, Some("false")));
        db.executor(0, &executor_blob(4, EXECUTION, None));
        db.step(
            &StepSpec::new(0, EXECUTION)
                .span(t0, t0 + Duration::seconds(seconds))
                .usage(output, 0),
        );
        assert!(
            poll(&mut fixture.monitor(), now()).is_empty(),
            "{output} over {seconds}"
        );
    }
    // Exactly 2,000 tok/s is allowed.
    let fixture = Fixture::new();
    let db = fixture.primary();
    db.generation(0, &generation_blob(MODEL, Some("false")));
    db.executor(0, &executor_blob(4, EXECUTION, None));
    db.step(
        &StepSpec::new(0, EXECUTION)
            .span(t0, t0 + Duration::seconds(10))
            .usage(20_000, 0),
    );
    assert_eq!(poll(&mut fixture.monitor(), now()).len(), 1);
}

#[test]
fn executions_with_missing_or_inconsistent_timestamps_or_calls_are_skipped() {
    let t0 = now() - Duration::seconds(120);
    let seconds = |value: i64| t0 + Duration::seconds(value);
    let scenarios: Vec<(&str, Vec<StepSpec>)> = vec![
        (
            "no model call",
            vec![StepSpec::new(0, EXECUTION).span(seconds(0), seconds(5))],
        ),
        (
            "call without completion",
            vec![StepSpec::new(0, EXECUTION)
                .created(seconds(0))
                .usage(500, 0)],
        ),
        (
            "call completed before created",
            vec![StepSpec::new(0, EXECUTION)
                .span(seconds(5), seconds(1))
                .usage(500, 0)],
        ),
        (
            "one bad call among good ones",
            vec![
                StepSpec::new(0, EXECUTION)
                    .span(seconds(0), seconds(5))
                    .usage(500, 0),
                StepSpec::new(1, EXECUTION)
                    .created(seconds(5))
                    .usage(500, 0),
            ],
        ),
    ];
    for (name, steps) in scenarios {
        let fixture = Fixture::new();
        let db = fixture.primary();
        db.generation(0, &generation_blob(MODEL, Some("false")));
        db.executor(0, &executor_blob(4, EXECUTION, None));
        for step in &steps {
            db.step(step);
        }
        assert!(poll(&mut fixture.monitor(), now()).is_empty(), "{name}");
    }
}

#[test]
fn an_execution_id_in_two_executor_rows_is_ambiguous() {
    let fixture = Fixture::new();
    let db = fixture.primary();
    finished_execution(&db, now() - Duration::seconds(120), 4);
    db.executor(1, &executor_blob(4, EXECUTION, None));
    assert!(poll(&mut fixture.monitor(), now()).is_empty());
}

#[test]
fn several_executions_of_one_conversation_are_separate_turns_with_their_own_steps() {
    let fixture = Fixture::new();
    let db = fixture.primary();
    let t0 = now() - Duration::seconds(600);
    finished_execution(&db, t0, 4);
    db.executor(
        1,
        &executor_blob(4, "second-execution", Some("gemini-3.8-flash-high")),
    );
    db.step(
        &StepSpec::new(10, "second-execution")
            .span(t0 + Duration::seconds(100), t0 + Duration::seconds(110))
            .usage(800, 0),
    );
    let mut turns = poll(&mut fixture.monitor(), now());
    turns.sort_by_key(|turn| turn.output_tokens);
    assert_eq!(turns.len(), 2);
    assert_eq!(turns[0].output_tokens, 800);
    assert_eq!(turns[0].reasoning_effort.as_deref(), Some("high"));
    assert_eq!(turns[1].output_tokens, 1_650);
    assert_ne!(turns[0].id, turns[1].id);
}

#[test]
fn malformed_blobs_are_skipped_without_panicking() {
    let fixture = Fixture::new();
    let db = fixture.primary();
    let t0 = now() - Duration::seconds(120);
    finished_execution(&db, t0, 4);
    // A second execution whose executor row is garbage: skipped, the first still measured.
    db.executor(5, &[0xff, 0xff, 0xff]);
    // A generation that is garbage: calls using it have no model.
    db.generation(3, &[0x0a, 0x7f]);
    let mut monitor = fixture.monitor();
    assert_eq!(poll(&mut monitor, now()).len(), 1);

    // An undecodable step cannot be attributed to an execution, so the whole database is
    // skipped (and retried on its next change) instead of undercounting.
    let corrupt = fixture.database("antigravity-ide", "corrupt-steps");
    finished_execution(&corrupt, t0, 4);
    corrupt.raw_step(40, false, Some(vec![0x0b, 0x01]));
    let mut monitor = AntigravityMonitor::new(fixture.root());
    let turns = poll(&mut monitor, now());
    assert_eq!(turns.len(), 1, "only the healthy database is measured");
}

#[test]
fn unreadable_databases_are_skipped_and_retried_when_they_change() {
    let fixture = Fixture::new();
    let folder = fixture.root().join("antigravity/conversations");
    fs::create_dir_all(&folder).unwrap();
    let path = folder.join(format!("{CONVERSATION}.db"));
    fs::write(&path, b"this is not a sqlite database at all").unwrap();
    let mut monitor = fixture.monitor();
    assert!(poll(&mut monitor, now()).is_empty());
    assert!(poll(&mut monitor, now()).is_empty());
    fs::remove_file(&path).unwrap();
    // Missing tables (a schema mismatch).
    Connection::open(&path)
        .unwrap()
        .execute_batch("CREATE TABLE steps (idx integer, metadata blob)")
        .unwrap();
    assert!(poll(&mut monitor, now()).is_empty());
    fs::remove_file(&path).unwrap();
    let db = Database::create(path);
    finished_execution(&db, now() - Duration::seconds(120), 4);
    // Discovery runs every ten seconds, but the file is tracked already.
    assert_eq!(poll(&mut monitor, now() + Duration::seconds(11)).len(), 1);
}

#[test]
fn only_conversation_databases_of_the_three_folders_are_read_and_pb_files_are_ignored() {
    let fixture = Fixture::new();
    let t0 = now() - Duration::seconds(120);
    for folder in ["antigravity", "antigravity-ide", "antigravity-cli"] {
        let db = fixture.database(folder, &format!("{folder}-conversation"));
        finished_execution(&db, t0, 4);
        db.executor(0, &executor_blob(4, &format!("{folder}-execution"), None));
        db.step(
            &StepSpec::new(0, &format!("{folder}-execution"))
                .span(t0, t0 + Duration::seconds(10))
                .usage(500, 0),
        );
    }
    // Legacy encrypted files, other folders, nested folders, other extensions and hidden files.
    let legacy = fixture.root().join("antigravity/conversations");
    fs::write(legacy.join("old.pb"), b"encrypted").unwrap();
    fs::write(legacy.join("notes.db-wal"), b"x").unwrap();
    fs::write(legacy.join(".hidden.db"), b"x").unwrap();
    fs::write(legacy.join(".db"), b"x").unwrap();
    for other in [
        "antigravity-browser-profile/conversations",
        "antigravity/other",
        "antigravity/conversations/nested",
    ] {
        let db = Database::create(fixture.root().join(other).join("elsewhere.db"));
        finished_execution(&db, t0, 4);
    }
    let mut monitor = fixture.monitor();
    let turns = poll(&mut monitor, now());
    assert_eq!(turns.len(), 3);
    assert!(turns.iter().all(|turn| turn.output_tokens == 500));
    // The surface is the Antigravity product that owns the folder the database was found in.
    for (folder, surface) in [
        ("antigravity", ToolSurface::Desktop),
        ("antigravity-ide", ToolSurface::Ide),
        ("antigravity-cli", ToolSurface::Cli),
    ] {
        let id = turn_id(
            &format!("{folder}-conversation"),
            &format!("{folder}-execution"),
        );
        let turn = turns.iter().find(|turn| turn.id == id).unwrap();
        assert_eq!(turn.surface, Some(surface), "{folder}");
        // It is shared as its category, always serialized.
        let sample = SharedSample::from_metric(turn, Uuid::new_v4()).unwrap();
        assert_eq!(sample.surface, Some(surface), "{folder}");
        let json = serde_json::to_value(&sample).unwrap();
        assert_eq!(
            json["surface"],
            match surface {
                ToolSurface::Desktop => "desktop",
                ToolSurface::Ide => "ide",
                _ => "cli",
            }
        );
    }
}

#[test]
fn databases_untouched_for_more_than_seven_days_are_not_opened() {
    let fixture = Fixture::new();
    let db = fixture.primary();
    finished_execution(&db, now() - Duration::seconds(120), 4);
    let path = db.path.clone();
    drop(db);
    let set_modified = |at: SystemTime| {
        File::options()
            .write(true)
            .open(&path)
            .unwrap()
            .set_times(FileTimes::new().set_modified(at))
            .unwrap()
    };
    let at = now();
    let eight_days = std::time::Duration::from_secs(8 * 24 * 3600);
    set_modified(SystemTime::from(at) - eight_days);
    let mut monitor = fixture.monitor();
    assert!(poll(&mut monitor, at).is_empty());
    assert_eq!(monitor.bytes_read_last_poll(), 0);
    // Six days is inside the retention.
    set_modified(SystemTime::from(at) - std::time::Duration::from_secs(6 * 24 * 3600));
    let mut monitor = fixture.monitor();
    assert_eq!(poll(&mut monitor, at).len(), 1);
}

// ---- live responses --------------------------------------------------------------------------

#[test]
fn live_responses_publish_once_and_only_for_calls_completed_after_the_monitor_started() {
    let fixture = Fixture::new();
    let db = fixture.primary();
    let started = now();
    let before = started - Duration::seconds(100);
    db.generation(0, &generation_blob(MODEL, Some("false")));
    db.executor(
        0,
        &executor_blob(0, EXECUTION, Some("gemini-3.8-flash-high")),
    );
    // Completed before the monitor started: never published, even though it qualifies.
    db.step(
        &StepSpec::new(0, EXECUTION)
            .span(before, before + Duration::seconds(10))
            .usage(500, 0),
    );
    let mut monitor = fixture.monitor();
    assert!(poll(&mut monitor, started).is_empty());
    assert!(monitor.take_live_responses().is_empty());

    // A call still running is not a response yet.
    let running = StepSpec::new(1, EXECUTION)
        .created(started + Duration::seconds(1))
        .usage(900, 0);
    db.step(&running);
    poll(&mut monitor, started + Duration::seconds(3));
    assert!(monitor.take_live_responses().is_empty());

    // It completes: published while its execution is still running.
    db.step(&running.clone().span(
        started + Duration::seconds(1),
        started + Duration::seconds(11),
    ));
    // A short call and a slow one do not qualify.
    db.step(
        &StepSpec::new(2, EXECUTION)
            .span(
                started + Duration::seconds(12),
                started + Duration::seconds(14),
            )
            .usage(50, 0),
    );
    poll(&mut monitor, started + Duration::seconds(15));
    let live = monitor.take_live_responses();
    assert_eq!(live.len(), 1);
    let response = &live[0];
    assert_eq!(response.model.as_deref(), Some(MODEL));
    assert_eq!(response.provider.as_deref(), Some("google"));
    assert_eq!(response.reasoning_effort.as_deref(), Some("high"));
    assert_eq!(response.client, ANTIGRAVITY_CLIENT);
    assert_eq!(response.source_kind.as_deref(), Some("primary"));
    assert_eq!(response.metric_version, ANTIGRAVITY_METRIC_VERSION);
    assert_eq!(response.output_tokens, 900);
    assert_eq!(response.duration_seconds, 10.0);
    assert_eq!(response.completed_at, started + Duration::seconds(11));

    // Re-reading the database (it changed again) never publishes the same call twice.
    db.step(
        &StepSpec::new(3, EXECUTION)
            .span(
                started + Duration::seconds(20),
                started + Duration::seconds(30),
            )
            .usage(700, 0),
    );
    poll(&mut monitor, started + Duration::seconds(31));
    let live = monitor.take_live_responses();
    assert_eq!(live.len(), 1);
    assert_eq!(live[0].output_tokens, 700);
    poll(&mut monitor, started + Duration::seconds(32));
    assert!(monitor.take_live_responses().is_empty());
}

#[test]
fn live_responses_without_an_executor_have_no_effort_and_without_a_model_are_not_published() {
    let fixture = Fixture::new();
    let db = fixture.primary();
    let started = now();
    db.generation(0, &generation_blob(MODEL, Some("false")));
    let mut monitor = fixture.monitor();
    poll(&mut monitor, started);
    let (from, to) = (
        started + Duration::seconds(1),
        started + Duration::seconds(11),
    );
    // No executor row at all: the effort is unknown.
    db.step(&StepSpec::new(0, "orphan").span(from, to).usage(500, 0));
    // A generation that does not exist: no model, so not published.
    db.step(
        &StepSpec::new(1, "orphan")
            .span(from, to)
            .usage(500, 0)
            .generation(42),
    );
    poll(&mut monitor, started + Duration::seconds(12));
    let live = monitor.take_live_responses();
    assert_eq!(live.len(), 1);
    assert_eq!(live[0].model.as_deref(), Some(MODEL));
    assert_eq!(live[0].reasoning_effort, None);
}

// ---- integration with the rest of the core -------------------------------------------------

#[test]
fn source_monitor_polls_antigravity_under_its_own_root_and_charges_a_bounded_budget() {
    let fixture = Fixture::new();
    let db = fixture.primary();
    finished_execution(&db, now() - Duration::seconds(120), 4);
    let empty = |name: &str| {
        let path = fixture.dir.path().join(name);
        fs::create_dir_all(&path).unwrap();
        path
    };
    let mut monitor = SourceMonitor::new(
        empty("codex"),
        empty("claude"),
        empty("grok"),
        fixture.root(),
        empty("opencode"),
    );
    assert_eq!(monitor.root("antigravity"), Some(&fixture.root()));
    let turns = monitor.poll(now()).unwrap();
    assert_eq!(turns.len(), 1);
    assert_eq!(turns[0].client, ANTIGRAVITY_CLIENT);
    assert!(monitor.bytes_read_last_poll() <= SourceMonitor::MAX_POLL_BYTES);
    assert!(!monitor.had_source_error());

    // Changing the root starts a fresh monitor on the new folder.
    monitor.set_root("antigravity", empty("nowhere")).unwrap();
    assert!(monitor.poll(now()).unwrap().is_empty());
    monitor.set_root("antigravity", fixture.root()).unwrap();
    assert_eq!(monitor.poll(now()).unwrap().len(), 1);
}

#[test]
fn antigravity_turns_are_shared_only_with_final_delegated_output_and_the_google_provider() {
    let fixture = Fixture::new();
    let db = fixture.primary();
    finished_execution(&db, now() - Duration::seconds(120), 4);
    let turn = poll(&mut fixture.monitor(), now()).remove(0);
    let sample = SharedSample::from_metric(&turn, Uuid::new_v4()).unwrap();
    assert_eq!(sample.client, "antigravity");
    assert_eq!(sample.parser_version, "antigravity-conversation-v1");
    assert_eq!(sample.metric_version, "antigravity-observed-execution-v1");
    assert_eq!(sample.provider, "google");
    assert_eq!(sample.model, MODEL);
    assert_eq!(sample.reasoning_effort, "medium");
    assert_eq!(sample.source_kind, "primary");
    assert_eq!(sample.delegated_output_tokens, Some(0));
    assert_eq!(sample.ttft_ms, None);
    assert_eq!(sample.response_count, Some(2));
    // Another tool's record never borrows the Google provider.
    let mut other = turn.clone();
    other.client = "codex".into();
    other.parser_version = "codex-rollout-v2".into();
    other.metric_version = "turn-v1".into();
    assert_eq!(
        SharedSample::from_metric(&other, Uuid::new_v4())
            .unwrap()
            .provider,
        "unknown"
    );
}

#[test]
fn the_google_badge_is_matched_by_model_prefix_or_provider() {
    assert_eq!(
        ProviderBadge::of(Some("gemini-3.8-flash"), None),
        ProviderBadge::Google
    );
    assert_eq!(
        ProviderBadge::of(Some("Gemini-3.8-pro"), Some("unknown")),
        ProviderBadge::Google
    );
    assert_eq!(
        ProviderBadge::of(Some("anything"), Some("google")),
        ProviderBadge::Google
    );
    assert_eq!(
        ProviderBadge::of(Some("claude-opus-4-6-thinking"), Some("unknown")),
        ProviderBadge::Anthropic
    );
    assert_eq!(ProviderBadge::of(None, None), ProviderBadge::Unknown);
    assert_eq!(ProviderBadge::Google.letter(), Some('G'));
    assert_eq!(ProviderBadge::Google.label(), "Google");
}

#[test]
fn unreadable_database_retry_delay_doubles_up_to_five_minutes() {
    let seconds: Vec<i64> = (1..=8)
        .map(|failures| crate::sqlite_read::retry_delay(failures).num_seconds())
        .collect();
    assert_eq!(seconds, [10, 20, 40, 80, 160, 300, 300, 300]);
}

// ---- event-driven polling ------------------------------------------------------------------------

fn changed(paths: &[&Path]) -> SourceChange {
    SourceChange {
        paths: paths.iter().map(|path| path.to_path_buf()).collect(),
        must_rescan: false,
    }
}

#[test]
fn only_a_conversation_database_change_wakes_a_poll() {
    let fixture = Fixture::new();
    let db = fixture.primary();
    finished_execution(&db, now() - Duration::seconds(120), 4);
    let mut monitor = fixture.monitor();
    let at = now();
    assert_eq!(poll(&mut monitor, at).len(), 1);
    // Everything is read: nothing to do, and a report that changed nothing leaves nothing to poll.
    assert_eq!(monitor.next_poll_deadline(at), None);
    assert!(!monitor.note_changes(&changed(&[&db.path])));
    assert_eq!(monitor.next_poll_deadline(at), None);

    // Neither the rest of the data folder nor a conversation folder's other files wake a poll.
    let root = fixture.root();
    let folder = db.path.parent().unwrap();
    let unrelated = [
        root.join("antigravity-browser-profile/Default/Cookies"),
        root.join("config/settings.json"),
        root.join("antigravity/brain/notes.md"),
        folder.join("legacy.pb"),
        folder.join(format!("{CONVERSATION}.db-shm")),
        folder.join(format!("{CONVERSATION}.db-journal")),
        folder.join(".hidden.db"),
        root.join("antigravity-ide/conversations/nested/other.db"),
    ];
    let paths: Vec<&Path> = unrelated.iter().map(PathBuf::as_path).collect();
    assert!(!monitor.note_changes(&changed(&paths)));
    assert_eq!(monitor.next_poll_deadline(at), None);

    // A write to the database, or to its write-ahead log, does.
    db.step(&StepSpec::new(9, "later-execution").created(now()));
    assert!(monitor.note_changes(&changed(&[&db.path])));
    assert_eq!(monitor.next_poll_deadline(at), Some(at));
    assert!(poll(&mut monitor, at).is_empty());
    assert_eq!(monitor.next_poll_deadline(at), None);
    let wal = PathBuf::from(format!("{}-wal", db.path.display()));
    db.step(&StepSpec::new(10, "later-execution").created(now()));
    assert!(monitor.note_changes(&changed(&[&wal])));
    assert_eq!(monitor.next_poll_deadline(at), Some(at));
    poll(&mut monitor, at);

    // A lost event is answered by a poll.
    assert!(monitor.note_changes(&SourceChange {
        paths: Default::default(),
        must_rescan: true,
    }));
    assert_eq!(monitor.next_poll_deadline(at), Some(at));
}

#[test]
fn a_new_database_is_found_when_reported_and_otherwise_by_the_five_minute_safety_net() {
    let fixture = Fixture::new();
    let first = fixture.primary();
    finished_execution(&first, now() - Duration::seconds(120), 4);
    let mut monitor = fixture.monitor();
    let at = now();
    assert_eq!(poll(&mut monitor, at).len(), 1);

    // A second conversation appears. An idle poll does not enumerate, so it is not found yet.
    let second = fixture.database("antigravity-cli", "second-conversation");
    finished_execution(&second, now() - Duration::seconds(100), 4);
    assert!(poll(&mut monitor, at + Duration::minutes(1)).is_empty());
    assert_eq!(monitor.bytes_read_last_poll(), 0);
    // The report of the new file wakes a poll that enumerates.
    assert!(monitor.note_changes(&changed(&[&second.path])));
    assert_eq!(monitor.next_poll_deadline(at), Some(at));
    let turns = poll(&mut monitor, at + Duration::minutes(1));
    assert_eq!(turns.len(), 1);
    assert_eq!(turns[0].surface, Some(ToolSurface::Cli));

    // Without any report the safety net finds it.
    let third = fixture.database("antigravity-ide", "third-conversation");
    finished_execution(&third, now() - Duration::seconds(90), 4);
    assert!(poll(&mut monitor, at + Duration::minutes(2)).is_empty());
    let turns = poll(&mut monitor, at + Duration::minutes(7));
    assert_eq!(turns.len(), 1);
    assert_eq!(turns[0].surface, Some(ToolSurface::Ide));
}

#[test]
fn the_deadline_is_now_for_deferred_reads_and_the_retry_time_for_a_failing_database() {
    let fixture = Fixture::new();
    let t0 = now() - Duration::seconds(120);
    for name in ["one", "two"] {
        let db = fixture.database("antigravity", name);
        finished_execution(&db, t0, 4);
    }
    let mut monitor = fixture.monitor();
    let at = now();
    // Only one database is read when the budget is used up by it; the other is deferred.
    assert_eq!(monitor.poll_with_budget(at, 1).unwrap().len(), 1);
    assert_eq!(monitor.next_poll_deadline(at), Some(at));
    assert_eq!(monitor.poll_with_budget(at, 1).unwrap().len(), 1);
    assert_eq!(monitor.next_poll_deadline(at), None);

    // A database that cannot be read is retried after a delay, not on every poll.
    let broken = fixture.root().join("antigravity/conversations/broken.db");
    fs::write(&broken, b"this is not a sqlite database at all").unwrap();
    assert!(monitor.note_changes(&changed(&[&broken])));
    assert_eq!(monitor.next_poll_deadline(at), Some(at));
    assert!(poll(&mut monitor, at).is_empty());
    assert_eq!(
        monitor.next_poll_deadline(at),
        Some(at + Duration::seconds(10))
    );
    // Once the delay is over the retry is due; a second failure doubles it.
    let later = at + Duration::seconds(11);
    assert_eq!(monitor.next_poll_deadline(later), Some(later));
    assert!(poll(&mut monitor, later).is_empty());
    assert_eq!(
        monitor.next_poll_deadline(later),
        Some(later + Duration::seconds(20))
    );
}

#[test]
fn source_monitor_routes_changes_by_root_wakes_on_them_and_watches_only_the_conversation_folders() {
    let fixture = Fixture::new();
    let db = fixture.primary();
    finished_execution(&db, now() - Duration::seconds(120), 4);
    let empty = |name: &str| {
        let path = fixture.dir.path().join(name);
        fs::create_dir_all(&path).unwrap();
        path
    };
    let mut monitor = SourceMonitor::new(
        empty("codex"),
        empty("claude"),
        empty("grok"),
        fixture.root(),
        empty("opencode"),
    );
    let at = now();
    assert_eq!(monitor.poll(at).unwrap().len(), 1);
    assert_eq!(monitor.next_poll_deadline(at), None);
    // A path of another root, or noise below the Antigravity root, wakes nothing.
    assert!(!monitor.note_changes(&changed(&[
        &fixture.dir.path().join("codex/rollout.jsonl"),
        &fixture.root().join("antigravity-browser-profile/x"),
    ])));
    assert_eq!(monitor.next_poll_deadline(at), None);
    db.step(&StepSpec::new(9, "later-execution").created(now()));
    assert!(monitor.note_changes(&changed(&[&db.path])));
    assert_eq!(monitor.next_poll_deadline(at), Some(at));

    // Only the three conversation folders are watched, each on its own and not below them.
    let folders = monitor.watch_folders("antigravity");
    let names: Vec<_> = folders.iter().map(|folder| folder.name).collect();
    assert_eq!(names, ["antigravity", "antigravity-ide", "antigravity-cli"]);
    assert!(folders.iter().all(|folder| !folder.recursive));
    assert_eq!(
        folders
            .iter()
            .map(|folder| folder.exists)
            .collect::<Vec<_>>(),
        [true, false, false]
    );
    assert_eq!(
        folders[0].path,
        fixture.root().join("antigravity/conversations")
    );
    assert_eq!(monitor.root_exists("antigravity"), Some(true));
    // The other tools are watched whole from their root.
    assert!(monitor.watch_folders("codex")[0].recursive);
    assert!(monitor.watch_folders("unknown").is_empty());
}
