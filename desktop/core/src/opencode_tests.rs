//! Tests for the OpenCode adapter over synthetic databases created with the exact `session` and
//! `message` schema OpenCode 1.18 writes (Drizzle), with JSON message data in its real shape.

use crate::monitor::SourceChange;
use crate::opencode_turns::{turn_id, version_is_measured};
use crate::sqlite_read::read_only_uri;
use crate::{
    OpenCodeMonitor, SharedSample, SourceMonitor, TurnMetric, OPENCODE_CLIENT,
    OPENCODE_METRIC_VERSION, OPENCODE_PARSER_VERSION,
};
use chrono::{DateTime, Duration, SubsecRound, Utc};
use rusqlite::{params, Connection};
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::fs;
use std::path::{Path, PathBuf};
use tempfile::TempDir;
use uuid::Uuid;

/// `.schema session` and `.schema message` of a real `opencode.db` (1.18.31).
const SCHEMA: &str = r#"
CREATE TABLE `session` (
	`id` text PRIMARY KEY,
	`project_id` text NOT NULL,
	`parent_id` text,
	`slug` text NOT NULL,
	`directory` text NOT NULL,
	`title` text NOT NULL,
	`version` text NOT NULL,
	`share_url` text,
	`summary_additions` integer,
	`summary_deletions` integer,
	`summary_files` integer,
	`summary_diffs` text,
	`revert` text,
	`permission` text,
	`time_created` integer NOT NULL,
	`time_updated` integer NOT NULL,
	`time_compacting` integer,
	`time_archived` integer, `workspace_id` text, `path` text, `agent` text, `model` text, `cost` real DEFAULT 0 NOT NULL, `tokens_input` integer DEFAULT 0 NOT NULL, `tokens_output` integer DEFAULT 0 NOT NULL, `tokens_reasoning` integer DEFAULT 0 NOT NULL, `tokens_cache_read` integer DEFAULT 0 NOT NULL, `tokens_cache_write` integer DEFAULT 0 NOT NULL, `metadata` text,
	CONSTRAINT `fk_session_project_id_project_id_fk` FOREIGN KEY (`project_id`) REFERENCES `project`(`id`) ON DELETE CASCADE
);
CREATE INDEX `session_project_idx` ON `session` (`project_id`);
CREATE INDEX `session_parent_idx` ON `session` (`parent_id`);
CREATE INDEX `session_workspace_idx` ON `session` (`workspace_id`);
CREATE TABLE `message` (
	`id` text PRIMARY KEY,
	`session_id` text NOT NULL,
	`time_created` integer NOT NULL,
	`time_updated` integer NOT NULL,
	`data` text NOT NULL,
	CONSTRAINT `fk_message_session_id_session_id_fk` FOREIGN KEY (`session_id`) REFERENCES `session`(`id`) ON DELETE CASCADE
);
CREATE INDEX `message_session_time_created_id_idx` ON `message` (`session_id`,`time_created`,`id`);
"#;

const SESSION: &str = "ses_primary";
const CHILD: &str = "ses_child";
const USER: &str = "msg_user";
const VERSION: &str = "1.18.31";

// ---- synthetic databases ---------------------------------------------------------------------

/// One assistant message (one model call) as OpenCode writes it into `message.data`.
#[derive(Clone)]
struct Call {
    id: String,
    session: String,
    parent: String,
    created: i64,
    completed: Option<i64>,
    updated: Option<i64>,
    output: Value,
    reasoning: Value,
    input: Option<i64>,
    read: Option<i64>,
    write: Option<i64>,
    model: Option<String>,
    provider: Option<String>,
    variant: Option<String>,
    finish: Option<String>,
    error: Option<String>,
}

impl Call {
    fn new(id: &str, parent: &str) -> Self {
        Self {
            id: id.to_owned(),
            session: SESSION.to_owned(),
            parent: parent.to_owned(),
            created: 0,
            completed: None,
            updated: None,
            output: json!(0),
            reasoning: json!(0),
            input: Some(100),
            read: Some(0),
            write: Some(0),
            model: Some("claude-opus-4-6".to_owned()),
            provider: Some("anthropic".to_owned()),
            variant: None,
            finish: None,
            error: None,
        }
    }

    fn session(mut self, session: &str) -> Self {
        self.session = session.to_owned();
        self
    }

    fn span(mut self, created: i64, completed: i64) -> Self {
        self.created = created;
        self.completed = Some(completed);
        self
    }

    fn running(mut self, created: i64) -> Self {
        self.created = created;
        self.completed = None;
        self
    }

    fn tokens(mut self, output: i64, reasoning: i64) -> Self {
        self.output = json!(output);
        self.reasoning = json!(reasoning);
        self
    }

    fn usage(mut self, input: i64, read: i64, write: i64) -> Self {
        (self.input, self.read, self.write) = (Some(input), Some(read), Some(write));
        self
    }

    fn model(mut self, model: &str, provider: &str) -> Self {
        self.model = Some(model.to_owned());
        self.provider = Some(provider.to_owned());
        self
    }

    fn variant(mut self, variant: &str) -> Self {
        self.variant = Some(variant.to_owned());
        self
    }

    fn finish(mut self, finish: &str) -> Self {
        self.finish = Some(finish.to_owned());
        self
    }

    fn error(mut self, name: &str) -> Self {
        self.error = Some(name.to_owned());
        self
    }

    fn data(&self) -> String {
        let mut cache = serde_json::Map::new();
        let mut tokens = serde_json::Map::new();
        tokens.insert("total".into(), json!(1234));
        tokens.insert("output".into(), self.output.clone());
        tokens.insert("reasoning".into(), self.reasoning.clone());
        if let Some(input) = self.input {
            tokens.insert("input".into(), json!(input));
        }
        if let Some(read) = self.read {
            cache.insert("read".into(), json!(read));
        }
        if let Some(write) = self.write {
            cache.insert("write".into(), json!(write));
        }
        tokens.insert("cache".into(), Value::Object(cache));
        let mut time = serde_json::Map::new();
        time.insert("created".into(), json!(self.created));
        if let Some(completed) = self.completed {
            time.insert("completed".into(), json!(completed));
        }
        let mut data = serde_json::Map::new();
        data.insert("role".into(), json!("assistant"));
        data.insert("parentID".into(), json!(self.parent));
        data.insert("time".into(), Value::Object(time));
        data.insert("tokens".into(), Value::Object(tokens));
        // Content-bearing and unrelated fields that must never be read.
        data.insert(
            "path".into(),
            json!({"cwd": "/secret/project", "root": "/secret"}),
        );
        data.insert("summary".into(), json!("secret summary text"));
        data.insert("cost".into(), json!(0.25));
        data.insert("agent".into(), json!("build"));
        for (key, value) in [
            ("modelID", &self.model),
            ("providerID", &self.provider),
            ("variant", &self.variant),
            ("finish", &self.finish),
        ] {
            if let Some(value) = value {
                data.insert(key.into(), json!(value));
            }
        }
        if let Some(name) = &self.error {
            data.insert(
                "error".into(),
                json!({"name": name, "data": {"message": "secret error text"}}),
            );
        }
        Value::Object(data).to_string()
    }
}

struct Database {
    path: PathBuf,
    connection: Connection,
    /// `time_updated` of the last write: OpenCode stamps rows with the wall clock, so it only
    /// grows, whatever the times inside the message say.
    clock: std::cell::Cell<i64>,
}

impl Database {
    fn create(path: PathBuf) -> Self {
        fs::create_dir_all(path.parent().unwrap()).unwrap();
        let connection = Connection::open(&path).unwrap();
        // The `project` table the real schema references is not needed to read; the bundled
        // SQLite enforces foreign keys by default, so tests that insert orphans turn it off.
        connection
            .pragma_update(None, "foreign_keys", false)
            .unwrap();
        connection.execute_batch(SCHEMA).unwrap();
        Self {
            path,
            connection,
            clock: std::cell::Cell::new(0),
        }
    }

    fn session(&self, id: &str, parent: Option<&str>, version: &str) {
        self.connection
            .execute(
                "INSERT OR REPLACE INTO session (id, project_id, parent_id, slug, directory, title, version, time_created, time_updated) \
                 VALUES (?1, 'proj', ?2, 'slug', '/secret/project', 'secret title', ?3, 1, 1)",
                params![id, parent, version],
            )
            .unwrap();
    }

    fn raw_message(&self, id: &str, session: &str, created: i64, updated: i64, data: &str) {
        self.clock.set(self.clock.get().max(updated));
        self.connection
            .execute(
                "INSERT OR REPLACE INTO message (id, session_id, time_created, time_updated, data) VALUES (?1, ?2, ?3, ?4, ?5)",
                params![id, session, created, updated, data],
            )
            .unwrap();
    }

    fn user(&self, id: &str, session: &str, created: i64) {
        let data = json!({
            "role": "user",
            "time": {"created": created},
            "agent": "build",
            "model": {"providerID": "anthropic", "modelID": "secret-model"},
            "summary": {"title": "secret prompt title"}
        });
        let updated = created.max(self.clock.get() + 1);
        self.raw_message(id, session, created, updated, &data.to_string());
    }

    fn call(&self, call: &Call) {
        let written = call
            .completed
            .unwrap_or(call.created)
            .max(self.clock.get() + 1);
        let updated = call.updated.unwrap_or(written);
        self.raw_message(&call.id, &call.session, call.created, updated, &call.data());
    }

    fn delete_message(&self, id: &str) {
        self.connection
            .execute("DELETE FROM message WHERE id = ?1", params![id])
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
        self.dir.path().join("opencode")
    }

    fn database(&self) -> Database {
        Database::create(self.root().join("opencode.db"))
    }

    fn monitor(&self) -> OpenCodeMonitor {
        OpenCodeMonitor::new(self.root())
    }
}

fn now() -> DateTime<Utc> {
    Utc::now().trunc_subsecs(0)
}

/// Ten minutes ago, in milliseconds: the start of the turns the tests build.
fn t0() -> i64 {
    (now() - Duration::minutes(10)).timestamp_millis()
}

fn sha256_hex(text: &str) -> String {
    format!("{:x}", Sha256::digest(text.as_bytes()))
}

fn poll(monitor: &mut OpenCodeMonitor, at: DateTime<Utc>) -> Vec<TurnMetric> {
    monitor.poll(at).unwrap()
}

/// A primary session with one user message answered by a tool-calling step and a final answer.
fn standard(db: &Database, t0: i64) {
    db.session(SESSION, None, VERSION);
    db.user(USER, SESSION, t0);
    db.call(
        &Call::new("msg_a1", USER)
            .span(t0 + 100, t0 + 5_000)
            .tokens(300, 50)
            .usage(1_000, 800, 0)
            .variant("high")
            .finish("tool-calls"),
    );
    db.call(
        &Call::new("msg_a2", USER)
            .span(t0 + 6_000, t0 + 16_000)
            .tokens(500, 100)
            .usage(2_000, 1_500, 200)
            .variant("high")
            .finish("stop"),
    );
}

// ---- turns -----------------------------------------------------------------------------------

#[test]
fn a_complete_multi_step_turn_has_exact_values() {
    let fixture = Fixture::new();
    let db = fixture.database();
    let t0 = t0();
    standard(&db, t0);
    let mut monitor = fixture.monitor();
    let turns = poll(&mut monitor, now());
    assert_eq!(turns.len(), 1);
    let turn = &turns[0];
    assert_eq!(turn.id, sha256_hex(&format!("opencode|{SESSION}|{USER}")));
    assert_eq!(turn.id, turn_id(SESSION, USER));
    assert_eq!(turn.client, OPENCODE_CLIENT);
    assert_eq!(turn.parser_version, OPENCODE_PARSER_VERSION);
    assert_eq!(turn.metric_version, OPENCODE_METRIC_VERSION);
    assert_eq!(turn.source_kind.as_deref(), Some("primary"));
    assert_eq!(turn.model.as_deref(), Some("claude-opus-4-6"));
    assert_eq!(turn.provider.as_deref(), Some("anthropic"));
    assert_eq!(turn.reasoning_effort.as_deref(), Some("high"));
    assert_eq!(turn.client_version.as_deref(), Some(VERSION));
    // Output counts visible output and reasoning: 300 + 50 + 500 + 100.
    assert_eq!(turn.output_tokens, 950);
    assert_eq!(turn.reasoning_output_tokens, Some(150));
    assert_eq!(turn.duration_seconds, 16.0);
    assert_eq!(turn.completed_at.timestamp_millis(), t0 + 16_000);
    assert_eq!(turn.codex_ttft_seconds, None);
    assert_eq!(turn.provider_region, None);
    assert_eq!(turn.surface, None);
    // Both steps qualify as responses: 350 tokens over 4.9 s and 600 over 10 s.
    assert_eq!(turn.response_count, Some(2));
    assert_eq!(turn.response_output_tokens, Some(950));
    assert!((turn.response_duration_seconds.unwrap() - 14.9).abs() < 1e-9);
    // Input includes cached tokens: (1000 + 800 + 0) + (2000 + 1500 + 200); Anthropic reports writes.
    assert_eq!(turn.input_tokens, Some(5_500));
    assert_eq!(turn.cache_read_input_tokens, Some(2_300));
    assert_eq!(turn.cache_write_input_tokens, Some(200));
    // No subagent work: final at emission.
    assert_eq!(turn.delegated_output_tokens, Some(0));
    // Emitted once.
    assert!(poll(&mut monitor, now()).is_empty());
    assert!(monitor.bytes_read_last_poll() == 0);
}

#[test]
fn a_turn_ending_in_tool_calls_is_emitted_once_it_completes_with_stop() {
    let fixture = Fixture::new();
    let db = fixture.database();
    let t0 = t0();
    db.session(SESSION, None, VERSION);
    db.user(USER, SESSION, t0);
    db.call(
        &Call::new("msg_a1", USER)
            .span(t0 + 100, t0 + 5_000)
            .tokens(300, 0)
            .finish("tool-calls"),
    );
    let mut monitor = fixture.monitor();
    assert!(poll(&mut monitor, now()).is_empty());
    // The next step is running: still incomplete.
    db.call(&Call::new("msg_a2", USER).running(t0 + 6_000).tokens(0, 0));
    assert!(poll(&mut monitor, now()).is_empty());
    db.call(
        &Call::new("msg_a2", USER)
            .span(t0 + 6_000, t0 + 12_000)
            .tokens(400, 0)
            .finish("stop"),
    );
    let turns = poll(&mut monitor, now());
    assert_eq!(turns.len(), 1);
    assert_eq!(turns[0].output_tokens, 700);
    assert!(poll(&mut monitor, now()).is_empty());
    // Other terminal finishes count; `unknown` and a missing finish do not.
    for (finish, emitted) in [
        ("length", true),
        ("content-filter", true),
        ("unknown", false),
    ] {
        let fixture = Fixture::new();
        let db = fixture.database();
        db.session(SESSION, None, VERSION);
        db.user(USER, SESSION, t0);
        db.call(
            &Call::new("msg_a1", USER)
                .span(t0 + 100, t0 + 5_000)
                .tokens(300, 0)
                .finish(finish),
        );
        assert_eq!(
            poll(&mut fixture.monitor(), now()).len(),
            usize::from(emitted),
            "{finish}"
        );
    }
}

#[test]
fn an_interrupted_turn_is_never_emitted() {
    let t0 = t0();
    // The user interrupts: OpenCode leaves a finish-less message that has time.completed, 0 tokens
    // and no error. It is the last message, so the turn is not an answer.
    let fixture = Fixture::new();
    let db = fixture.database();
    db.session(SESSION, None, VERSION);
    db.user(USER, SESSION, t0);
    db.call(
        &Call::new("msg_a1", USER)
            .span(t0 + 100, t0 + 5_000)
            .tokens(300, 0)
            .finish("tool-calls"),
    );
    db.call(
        &Call::new("msg_a2", USER)
            .span(t0 + 6_000, t0 + 6_050)
            .tokens(0, 0),
    );
    let mut monitor = fixture.monitor();
    assert!(poll(&mut monitor, now()).is_empty());
    // And it stays unemitted however often it is evaluated.
    assert!(poll(&mut monitor, now() + Duration::minutes(40)).is_empty());
}

#[test]
fn a_failed_message_means_no_turn() {
    let t0 = t0();
    for error in [
        "MessageAbortedError",
        "APIError",
        "UnknownError",
        "ProviderAuthError",
    ] {
        let fixture = Fixture::new();
        let db = fixture.database();
        db.session(SESSION, None, VERSION);
        db.user(USER, SESSION, t0);
        db.call(
            &Call::new("msg_a1", USER)
                .span(t0 + 100, t0 + 5_000)
                .tokens(300, 0)
                .finish("tool-calls"),
        );
        // Even with a fine final answer after it, a failed step voids the turn.
        db.call(
            &Call::new("msg_a2", USER)
                .span(t0 + 6_000, t0 + 9_000)
                .tokens(300, 0)
                .error(error),
        );
        db.call(
            &Call::new("msg_a3", USER)
                .span(t0 + 10_000, t0 + 12_000)
                .tokens(300, 0)
                .finish("stop"),
        );
        assert!(poll(&mut fixture.monitor(), now()).is_empty(), "{error}");
    }
}

#[test]
fn mixed_models_providers_and_efforts_leave_them_unknown() {
    let fixture = Fixture::new();
    let db = fixture.database();
    let t0 = t0();
    db.session(SESSION, None, VERSION);
    db.user(USER, SESSION, t0);
    db.call(
        &Call::new("msg_a1", USER)
            .span(t0 + 100, t0 + 5_000)
            .tokens(300, 0)
            .model("claude-opus-4-6", "anthropic")
            .variant("high")
            .finish("tool-calls"),
    );
    db.call(
        &Call::new("msg_a2", USER)
            .span(t0 + 6_000, t0 + 12_000)
            .tokens(300, 0)
            .model("gpt-5", "openai")
            .variant("low")
            .finish("stop"),
    );
    let turn = &poll(&mut fixture.monitor(), now())[0];
    assert_eq!(turn.model, None);
    assert_eq!(turn.provider.as_deref(), Some("unknown"));
    assert_eq!(turn.reasoning_effort, None);
    // The same model on two providers keeps the model and makes the provider unknown.
    let fixture = Fixture::new();
    let db = fixture.database();
    db.session(SESSION, None, VERSION);
    db.user(USER, SESSION, t0);
    db.call(
        &Call::new("msg_a1", USER)
            .span(t0 + 100, t0 + 5_000)
            .tokens(300, 0)
            .model("m", "anthropic")
            .finish("tool-calls"),
    );
    db.call(
        &Call::new("msg_a2", USER)
            .span(t0 + 6_000, t0 + 12_000)
            .tokens(300, 0)
            .model("m", "openrouter")
            .finish("stop"),
    );
    let turn = &poll(&mut fixture.monitor(), now())[0];
    assert_eq!(turn.model.as_deref(), Some("m"));
    assert_eq!(turn.provider.as_deref(), Some("unknown"));
}

#[test]
fn only_a_shared_effort_variant_is_an_effort() {
    let t0 = t0();
    for (variant, effort) in [
        (Some("minimal"), Some("minimal")),
        (Some("low"), Some("low")),
        (Some("medium"), Some("medium")),
        (Some("high"), Some("high")),
        (Some("xhigh"), Some("xhigh")),
        (Some("max"), Some("max")),
        (Some("thinking"), None),
        (Some("Fast!"), None),
        (None, None),
    ] {
        let fixture = Fixture::new();
        let db = fixture.database();
        db.session(SESSION, None, VERSION);
        db.user(USER, SESSION, t0);
        let mut call = Call::new("msg_a1", USER)
            .span(t0 + 100, t0 + 5_000)
            .tokens(300, 0)
            .finish("stop");
        call.variant = variant.map(str::to_owned);
        db.call(&call);
        let turn = &poll(&mut fixture.monitor(), now())[0];
        assert_eq!(turn.reasoning_effort.as_deref(), effort, "{variant:?}");
    }
}

#[test]
fn the_raw_provider_stays_local_and_is_never_shared() {
    let t0 = t0();
    let provider_of = |provider: Option<&str>| {
        let fixture = Fixture::new();
        let db = fixture.database();
        db.session(SESSION, None, VERSION);
        db.user(USER, SESSION, t0);
        let mut call = Call::new("msg_a1", USER)
            .span(t0 + 100, t0 + 5_000)
            .tokens(300, 0)
            .finish("stop");
        call.provider = provider.map(str::to_owned);
        db.call(&call);
        poll(&mut fixture.monitor(), now()).remove(0)
    };
    // The shared providers map to themselves; a missing id or an unusable one is unknown.
    for provider in ["anthropic", "openai", "google", "xai"] {
        assert_eq!(
            provider_of(Some(provider)).provider.as_deref(),
            Some(provider)
        );
    }
    assert_eq!(provider_of(None).provider.as_deref(), Some("unknown"));
    assert_eq!(
        provider_of(Some("Has Spaces")).provider.as_deref(),
        Some("unknown")
    );
    assert_eq!(
        provider_of(Some("UPPER")).provider.as_deref(),
        Some("unknown")
    );
    assert_eq!(
        provider_of(Some(&"a".repeat(41))).provider.as_deref(),
        Some("unknown")
    );
    // Gateways, vendor plans and local servers keep their id locally...
    for raw in [
        "openrouter",
        "kimi-for-coding",
        "amazon-bedrock",
        "google-vertex",
        "myomlx",
        "a.b_c-1",
    ] {
        let turn = provider_of(Some(raw));
        assert_eq!(turn.provider.as_deref(), Some(raw));
        // ...but SharedSample refuses the record.
        assert!(
            SharedSample::from_metric(&turn, Uuid::new_v4()).is_none(),
            "{raw}"
        );
    }
    // The shared ones travel.
    for (provider, shared) in [
        (Some("anthropic"), "anthropic"),
        (Some("openai"), "openai"),
        (Some("google"), "google"),
        (Some("xai"), "xai"),
        (None, "unknown"),
        (Some("Has Spaces"), "unknown"),
    ] {
        let sample = SharedSample::from_metric(&provider_of(provider), Uuid::new_v4()).unwrap();
        assert_eq!(sample.provider, shared);
        assert_eq!(sample.client, "opencode");
        assert_eq!(sample.parser_version, "opencode-db-v1");
        assert_eq!(sample.metric_version, "opencode-observed-turn-v1");
        assert_eq!(sample.surface, None);
        assert_eq!(sample.ttft_ms, None);
        assert_eq!(sample.delegated_output_tokens, Some(0));
    }
}

#[test]
fn prompt_cache_needs_both_counts_and_writes_are_anthropic_only() {
    let t0 = t0();
    let turn_with = |call: Call| {
        let fixture = Fixture::new();
        let db = fixture.database();
        db.session(SESSION, None, VERSION);
        db.user(USER, SESSION, t0);
        db.call(&call);
        poll(&mut fixture.monitor(), now()).remove(0)
    };
    let base = Call::new("msg_a1", USER)
        .span(t0 + 100, t0 + 5_000)
        .tokens(300, 0)
        .finish("stop");
    let anthropic = turn_with(base.clone().usage(1_000, 400, 50));
    assert_eq!(
        (
            anthropic.input_tokens,
            anthropic.cache_read_input_tokens,
            anthropic.cache_write_input_tokens
        ),
        (Some(1_450), Some(400), Some(50))
    );
    // Other providers log a write of 0 that is not a report.
    let other = turn_with(base.clone().model("m", "openai").usage(1_000, 400, 0));
    assert_eq!(
        (
            other.input_tokens,
            other.cache_read_input_tokens,
            other.cache_write_input_tokens
        ),
        (Some(1_400), Some(400), None)
    );
    // An absent write counts as 0 for the total.
    let mut no_write = base.clone().usage(1_000, 400, 0);
    no_write.write = None;
    assert_eq!(turn_with(no_write).cache_write_input_tokens, Some(0));
    // A message without tokens.input or tokens.cache.read makes all three null.
    for missing in 0..2 {
        let mut call = base.clone().usage(1_000, 400, 50);
        if missing == 0 {
            call.input = None;
        } else {
            call.read = None;
        }
        let turn = turn_with(call);
        assert_eq!(
            (
                turn.input_tokens,
                turn.cache_read_input_tokens,
                turn.cache_write_input_tokens
            ),
            (None, None, None)
        );
        // The turn itself is unaffected.
        assert_eq!(turn.output_tokens, 300);
    }
    // 0 is a value: a request that read nothing from the cache.
    let zero = turn_with(base.usage(0, 0, 0));
    assert_eq!(
        (zero.input_tokens, zero.cache_read_input_tokens),
        (Some(0), Some(0))
    );
}

#[test]
fn sessions_below_the_version_floor_are_not_measured() {
    let t0 = t0();
    for (version, measured) in [
        ("1.13.9", false),
        ("1.2.27", false),
        ("1.0.126", false),
        ("0.99.0", false),
        ("1", false),
        ("garbage", false),
        ("", false),
        ("1.14", true),
        ("1.14.0", true),
        ("1.14.21", true),
        ("1.18.31", true),
        ("2.0.0", true),
        ("1.14.0.1", false),
    ] {
        assert_eq!(version_is_measured(version), measured, "{version}");
        let fixture = Fixture::new();
        let db = fixture.database();
        db.session(SESSION, None, version);
        db.user(USER, SESSION, t0);
        db.call(
            &Call::new("msg_a1", USER)
                .span(t0 + 100, t0 + 5_000)
                .tokens(300, 0)
                .finish("stop"),
        );
        let turns = poll(&mut fixture.monitor(), now());
        assert_eq!(turns.len(), usize::from(measured), "{version}");
        if measured {
            assert_eq!(turns[0].client_version.as_deref(), Some(version));
        }
    }
}

#[test]
fn invalid_token_counts_make_the_message_and_so_the_turn_unmeasurable() {
    let t0 = t0();
    for output in [json!(-1), json!(1.5), json!("12"), json!(100_000_001)] {
        let fixture = Fixture::new();
        let db = fixture.database();
        db.session(SESSION, None, VERSION);
        db.user(USER, SESSION, t0);
        let mut call = Call::new("msg_a1", USER)
            .span(t0 + 100, t0 + 5_000)
            .finish("stop");
        call.output = output.clone();
        db.call(&call);
        assert!(poll(&mut fixture.monitor(), now()).is_empty(), "{output}");
    }
    // Absent counts are 0, not malformed.
    let fixture = Fixture::new();
    let db = fixture.database();
    db.session(SESSION, None, VERSION);
    db.user(USER, SESSION, t0);
    db.raw_message(
        "msg_a1",
        SESSION,
        t0 + 100,
        t0 + 5_000,
        &json!({"role":"assistant","parentID":USER,"modelID":"m","providerID":"openai","finish":"stop",
                "time":{"created":t0 + 100,"completed":t0 + 5_000},"tokens":{"input":10,"cache":{"read":0}}})
        .to_string(),
    );
    let turn = &poll(&mut fixture.monitor(), now())[0];
    assert_eq!(turn.output_tokens, 0);
    assert_eq!(turn.reasoning_output_tokens, Some(0));
}

#[test]
fn implausibly_fast_or_instant_turns_are_not_emitted() {
    let t0 = t0();
    // 20,001 tokens in 10 s is over 2,000 tok/s; exactly 2,000 tok/s is fine.
    for (output, millis, emitted) in [
        (20_001, 10_000, false),
        (20_000, 10_000, true),
        (500, 0, false),
    ] {
        let fixture = Fixture::new();
        let db = fixture.database();
        db.session(SESSION, None, VERSION);
        db.user(USER, SESSION, t0);
        db.call(
            &Call::new("msg_a1", USER)
                .span(t0, t0 + millis)
                .tokens(output, 0)
                .finish("stop"),
        );
        assert_eq!(
            poll(&mut fixture.monitor(), now()).len(),
            usize::from(emitted),
            "{output} in {millis}"
        );
    }
}

#[test]
fn only_qualifying_steps_count_as_responses() {
    let fixture = Fixture::new();
    let db = fixture.database();
    let t0 = t0() - 3_000_000;
    db.session(SESSION, None, VERSION);
    db.user(USER, SESSION, t0);
    // 199 tokens (too short), 5,000 over 700 s (too long), 500 over 10 s.
    db.call(
        &Call::new("msg_a1", USER)
            .span(t0 + 100, t0 + 10_100)
            .tokens(199, 0)
            .finish("tool-calls"),
    );
    db.call(
        &Call::new("msg_a2", USER)
            .span(t0 + 11_000, t0 + 711_000)
            .tokens(5_000, 0)
            .finish("tool-calls"),
    );
    db.call(
        &Call::new("msg_a3", USER)
            .span(t0 + 712_000, t0 + 722_000)
            .tokens(300, 200)
            .finish("stop"),
    );
    let turn = &poll(&mut fixture.monitor(), now())[0];
    assert_eq!(turn.output_tokens, 5_699);
    assert_eq!(turn.response_count, Some(1));
    assert_eq!(turn.response_output_tokens, Some(500));
    assert_eq!(turn.response_duration_seconds, Some(10.0));
}

#[test]
fn several_turns_of_one_session_are_separate_and_a_follow_up_message_is_its_own_turn() {
    let fixture = Fixture::new();
    let db = fixture.database();
    let t0 = t0();
    standard(&db, t0);
    db.user("msg_user_2", SESSION, t0 + 3_000);
    db.call(
        &Call::new("msg_b1", "msg_user_2")
            .span(t0 + 3_100, t0 + 20_000)
            .tokens(900, 0)
            .finish("stop"),
    );
    let mut turns = poll(&mut fixture.monitor(), now());
    turns.sort_by_key(|turn| turn.output_tokens);
    assert_eq!(turns.len(), 2);
    assert_eq!(turns[0].output_tokens, 900);
    assert_eq!(turns[0].duration_seconds, 17.0);
    assert_eq!(turns[1].output_tokens, 950);
    assert_ne!(turns[0].id, turns[1].id);
}

#[test]
fn a_user_message_without_answers_and_other_roles_are_ignored() {
    let fixture = Fixture::new();
    let db = fixture.database();
    let t0 = t0();
    db.session(SESSION, None, VERSION);
    db.user(USER, SESSION, t0);
    db.raw_message(
        "msg_system",
        SESSION,
        t0,
        t0,
        &json!({"role":"system"}).to_string(),
    );
    db.raw_message("msg_odd", SESSION, t0, t0, &json!({"role": 5}).to_string());
    db.raw_message("msg_bad", SESSION, t0, t0, "this is not json {");
    db.raw_message("msg_array", SESSION, t0, t0, "[1,2]");
    assert!(poll(&mut fixture.monitor(), now()).is_empty());
    // A corrupt row never fails the read of the healthy ones.
    standard_with_noise(&fixture);
}

fn standard_with_noise(fixture: &Fixture) {
    let db = Database::create(fixture.root().join("other").join("opencode.db"));
    standard(&db, t0());
    db.raw_message("msg_bad", SESSION, t0(), t0(), "this is not json {");
    let mut monitor = OpenCodeMonitor::new(fixture.root().join("other"));
    assert_eq!(poll(&mut monitor, now()).len(), 1);
}

// ---- subagent sessions and delegated output ---------------------------------------------------

/// A subagent session started by the standard turn: a user message and one assistant message
/// created inside the turn window (`t0 .. t0 + 16 s`).
fn subagent(db: &Database, t0: i64) {
    db.session(CHILD, Some(SESSION), VERSION);
    db.user("msg_child_user", CHILD, t0 + 1_500);
}

#[test]
fn subagent_sessions_produce_no_turn_and_their_output_is_delegated_to_the_primary_turn() {
    let fixture = Fixture::new();
    let db = fixture.database();
    let t0 = t0();
    standard(&db, t0);
    subagent(&db, t0);
    // Still running when the primary turn is read: delegated output is not final.
    let running = Call::new("msg_c1", "msg_child_user")
        .session(CHILD)
        .running(t0 + 2_000)
        .tokens(0, 0);
    db.call(&running);
    let mut monitor = fixture.monitor();
    let first = poll(&mut monitor, now());
    assert_eq!(first.len(), 1, "the child session has no turn of its own");
    assert_eq!(first[0].id, turn_id(SESSION, USER));
    assert_eq!(first[0].delegated_output_tokens, None);
    assert_eq!(first[0].output_tokens, 950);
    // Nothing new while it is still running.
    assert!(poll(&mut monitor, now()).is_empty());

    // It finishes, with reasoning; a grandchild session and a failed step count too, and
    // messages created outside the turn's window do not.
    db.call(
        &running
            .clone()
            .span(t0 + 2_000, t0 + 9_000)
            .tokens(400, 100)
            .finish("stop"),
    );
    db.session("ses_grandchild", Some(CHILD), VERSION);
    db.call(
        &Call::new("msg_g1", "msg_gu")
            .session("ses_grandchild")
            .span(t0 + 3_000, t0 + 4_000)
            .tokens(70, 0)
            .finish("stop"),
    );
    db.call(
        &Call::new("msg_c2", "msg_child_user")
            .session(CHILD)
            .span(t0 + 4_000, t0 + 5_000)
            .tokens(30, 0)
            .error("APIError"),
    );
    db.call(
        &Call::new("msg_early", "msg_child_user")
            .session(CHILD)
            .span(t0 - 5_000, t0 - 4_000)
            .tokens(1_000, 0)
            .finish("stop"),
    );
    db.call(
        &Call::new("msg_late", "msg_child_user")
            .session(CHILD)
            .span(t0 + 20_000, t0 + 21_000)
            .tokens(2_000, 0)
            .finish("stop"),
    );
    let second = poll(&mut monitor, now());
    assert_eq!(second.len(), 1);
    // The same id, now with the delegated total: 500 + 70 + 30.
    assert_eq!(second[0].id, first[0].id);
    assert_eq!(second[0].delegated_output_tokens, Some(600));
    let mut settled = second[0].clone();
    settled.delegated_output_tokens = None;
    assert_eq!(settled, first[0]);
    // Final turns are not emitted again.
    assert!(poll(&mut monitor, now()).is_empty());
    // Shared once final, never before.
    assert!(SharedSample::from_metric(&first[0], Uuid::new_v4()).is_none());
    assert!(SharedSample::from_metric(&second[0], Uuid::new_v4()).is_some());
}

#[test]
fn unfinished_delegated_work_stops_blocking_thirty_minutes_after_the_turn_ended() {
    let fixture = Fixture::new();
    let db = fixture.database();
    let t0 = t0();
    standard(&db, t0);
    subagent(&db, t0);
    db.call(
        &Call::new("msg_c1", "msg_child_user")
            .session(CHILD)
            .span(t0 + 2_000, t0 + 9_000)
            .tokens(400, 0)
            .finish("stop"),
    );
    db.call(
        &Call::new("msg_c2", "msg_child_user")
            .session(CHILD)
            .running(t0 + 10_000)
            .tokens(77, 0),
    );
    let mut monitor = fixture.monitor();
    let at = now();
    assert_eq!(poll(&mut monitor, at)[0].delegated_output_tokens, None);
    // Without any database change, time alone settles it, ignoring the unfinished message.
    let completed = DateTime::<Utc>::from_timestamp_millis(t0 + 16_000).unwrap();
    assert!(poll(&mut monitor, completed + Duration::minutes(29)).is_empty());
    let settled = poll(&mut monitor, completed + Duration::minutes(31));
    assert_eq!(settled.len(), 1);
    assert_eq!(settled[0].id, turn_id(SESSION, USER));
    assert_eq!(settled[0].delegated_output_tokens, Some(400));
    assert!(poll(&mut monitor, completed + Duration::minutes(32)).is_empty());
}

#[test]
fn subagent_sessions_below_the_version_floor_add_no_delegated_output() {
    let fixture = Fixture::new();
    let db = fixture.database();
    let t0 = t0();
    standard(&db, t0);
    db.session(CHILD, Some(SESSION), "1.2.27");
    db.call(
        &Call::new("msg_c1", "msg_child_user")
            .session(CHILD)
            .span(t0 + 2_000, t0 + 9_000)
            .tokens(400, 0)
            .finish("stop"),
    );
    assert_eq!(
        poll(&mut fixture.monitor(), now())[0].delegated_output_tokens,
        Some(0)
    );
}

// ---- incremental reads ------------------------------------------------------------------------

#[test]
fn later_reads_merge_updated_messages_and_never_emit_a_turn_twice() {
    let fixture = Fixture::new();
    let db = fixture.database();
    let t0 = t0();
    standard(&db, t0);
    let mut monitor = fixture.monitor();
    assert_eq!(poll(&mut monitor, now()).len(), 1);
    let full_read = monitor.bytes_read_last_poll();
    assert!(full_read > 0);

    // A new turn arrives with a running step that completes in a later update of the same row.
    db.user("msg_user_2", SESSION, t0 + 60_000);
    let running = Call::new("msg_b1", "msg_user_2")
        .running(t0 + 60_100)
        .tokens(0, 0);
    db.call(&running);
    assert!(poll(&mut monitor, now()).is_empty());
    let incremental = monitor.bytes_read_last_poll();
    assert!(
        incremental > 0 && incremental < full_read,
        "{incremental} < {full_read}"
    );
    let mut done = running
        .clone()
        .span(t0 + 60_100, t0 + 70_000)
        .tokens(800, 0)
        .finish("stop");
    done.updated = Some(t0 + 70_000);
    db.call(&done);
    let turns = poll(&mut monitor, now());
    assert_eq!(turns.len(), 1);
    assert_eq!(turns[0].id, turn_id(SESSION, "msg_user_2"));
    assert_eq!(turns[0].output_tokens, 800);
    // Nothing is emitted again, however many times it is read.
    for _ in 0..3 {
        db.call(&done);
        assert!(poll(&mut monitor, now()).is_empty());
    }
}

#[test]
fn a_new_session_named_by_a_later_message_is_looked_up() {
    let fixture = Fixture::new();
    let db = fixture.database();
    let t0 = t0();
    standard(&db, t0);
    let mut monitor = fixture.monitor();
    assert_eq!(poll(&mut monitor, now()).len(), 1);
    db.session("ses_second", None, "1.17.20");
    db.user("msg_s2_user", "ses_second", t0 + 30_000);
    db.call(
        &Call::new("msg_s2_a", "msg_s2_user")
            .session("ses_second")
            .span(t0 + 30_100, t0 + 40_000)
            .tokens(500, 0)
            .finish("stop"),
    );
    let turns = poll(&mut monitor, now());
    assert_eq!(turns.len(), 1);
    assert_eq!(turns[0].client_version.as_deref(), Some("1.17.20"));
    // A message of a session the database does not have is dropped.
    db.raw_message(
        "msg_orphan",
        "ses_missing",
        t0,
        t0 + 50_000,
        &Call::new("x", "y").span(t0, t0 + 1).data(),
    );
    assert!(poll(&mut monitor, now()).is_empty());
}

#[test]
fn a_full_reread_every_five_minutes_drops_messages_opencode_deleted() {
    let fixture = Fixture::new();
    let db = fixture.database();
    let t0 = t0();
    standard(&db, t0);
    subagent(&db, t0);
    db.call(
        &Call::new("msg_c1", "msg_child_user")
            .session(CHILD)
            .running(t0 + 2_000)
            .tokens(0, 0),
    );
    let mut monitor = fixture.monitor();
    let start = now();
    assert_eq!(poll(&mut monitor, start)[0].delegated_output_tokens, None);
    // OpenCode reverts: the running subagent message disappears, and the database changes.
    db.delete_message("msg_c1");
    db.user("msg_user_3", SESSION, t0 + 100_000);
    // An incremental read does not notice the deletion...
    assert!(poll(&mut monitor, start + Duration::minutes(1)).is_empty());
    // ...the full re-read, which runs when the database changes after five minutes, does.
    db.user("msg_user_4", SESSION, t0 + 200_000);
    let settled = poll(&mut monitor, start + Duration::minutes(6));
    assert_eq!(settled.len(), 1);
    assert_eq!(settled[0].delegated_output_tokens, Some(0));
}

#[test]
fn messages_older_than_the_retention_are_not_read() {
    let fixture = Fixture::new();
    let db = fixture.database();
    let old = (now() - Duration::days(8)).timestamp_millis();
    db.session(SESSION, None, VERSION);
    db.user(USER, SESSION, old);
    db.call(
        &Call::new("msg_a1", USER)
            .span(old + 100, old + 5_000)
            .tokens(300, 0)
            .finish("stop"),
    );
    assert!(poll(&mut fixture.monitor(), now()).is_empty());
    // A database untouched for more than seven days is not opened at all.
    let path = db.path.clone();
    drop(db);
    let eight_days = std::time::Duration::from_secs(8 * 24 * 3600);
    fs::File::options()
        .write(true)
        .open(&path)
        .unwrap()
        .set_times(
            fs::FileTimes::new().set_modified(std::time::SystemTime::from(now()) - eight_days),
        )
        .unwrap();
    let mut monitor = fixture.monitor();
    assert!(poll(&mut monitor, now()).is_empty());
    assert_eq!(monitor.bytes_read_last_poll(), 0);
}

// ---- live responses ---------------------------------------------------------------------------

#[test]
fn live_responses_publish_once_for_primary_sessions_and_only_after_the_monitor_started() {
    let fixture = Fixture::new();
    let db = fixture.database();
    let started = now();
    let s = started.timestamp_millis();
    db.session(SESSION, None, VERSION);
    db.session(CHILD, Some(SESSION), VERSION);
    db.session("ses_old", None, "1.2.27");
    db.user(USER, SESSION, s - 120_000);
    // Completed before the monitor started: never live, even though it qualifies.
    db.call(
        &Call::new("msg_before", USER)
            .span(s - 100_000, s - 90_000)
            .tokens(500, 0)
            .finish("tool-calls"),
    );
    let mut monitor = fixture.monitor();
    poll(&mut monitor, started);
    assert!(monitor.take_live_responses().is_empty());

    // A running step is not a response yet.
    db.call(
        &Call::new("msg_live", USER)
            .variant("high")
            .model("gpt-5", "openai")
            .running(s + 1_000)
            .tokens(0, 0),
    );
    poll(&mut monitor, started + Duration::seconds(2));
    assert!(monitor.take_live_responses().is_empty());
    // It completes: published, with its own model, provider and effort.
    db.call(
        &Call::new("msg_live", USER)
            .variant("high")
            .model("gpt-5", "openai")
            .span(s + 1_000, s + 11_000)
            .tokens(700, 50)
            .finish("tool-calls"),
    );
    // Not qualifying (short, failed), a subagent step and an old-version session: not published.
    db.call(
        &Call::new("msg_short", USER)
            .span(s + 12_000, s + 13_000)
            .tokens(50, 0)
            .finish("tool-calls"),
    );
    db.call(
        &Call::new("msg_failed", USER)
            .span(s + 12_000, s + 22_000)
            .tokens(900, 0)
            .error("APIError"),
    );
    db.call(
        &Call::new("msg_child", "msg_cu")
            .session(CHILD)
            .span(s + 12_000, s + 22_000)
            .tokens(900, 0)
            .finish("stop"),
    );
    db.call(
        &Call::new("msg_oldv", "msg_ou")
            .session("ses_old")
            .span(s + 12_000, s + 22_000)
            .tokens(900, 0)
            .finish("stop"),
    );
    poll(&mut monitor, started + Duration::seconds(30));
    let live = monitor.take_live_responses();
    assert_eq!(live.len(), 1);
    let response = &live[0];
    assert_eq!(response.model.as_deref(), Some("gpt-5"));
    assert_eq!(response.provider.as_deref(), Some("openai"));
    assert_eq!(response.reasoning_effort.as_deref(), Some("high"));
    assert_eq!(response.client, OPENCODE_CLIENT);
    assert_eq!(response.source_kind.as_deref(), Some("primary"));
    assert_eq!(response.metric_version, OPENCODE_METRIC_VERSION);
    assert_eq!(response.output_tokens, 750);
    assert_eq!(response.duration_seconds, 10.0);
    assert_eq!(response.completed_at.timestamp_millis(), s + 11_000);

    // Re-reading (the same rows touched again, or a full re-read) never publishes it twice.
    db.call(
        &Call::new("msg_live", USER)
            .variant("high")
            .model("gpt-5", "openai")
            .span(s + 1_000, s + 11_000)
            .tokens(700, 50)
            .finish("tool-calls"),
    );
    poll(&mut monitor, started + Duration::seconds(40));
    poll(&mut monitor, started + Duration::minutes(7));
    assert!(monitor.take_live_responses().is_empty());
    // A raw provider is published as such (it is only blocked from sharing).
    db.call(
        &Call::new("msg_raw", USER)
            .model("k2p5", "kimi-for-coding")
            .span(s + 50_000, s + 60_000)
            .tokens(400, 0)
            .finish("stop"),
    );
    poll(&mut monitor, started + Duration::minutes(8));
    assert_eq!(
        monitor.take_live_responses()[0].provider.as_deref(),
        Some("kimi-for-coding")
    );
}

// ---- reading safely ---------------------------------------------------------------------------

#[test]
fn reading_never_changes_the_database_and_sees_write_ahead_log_content() {
    let fixture = Fixture::new();
    let db = fixture.database();
    db.connection
        .pragma_update(None, "journal_mode", "WAL")
        .unwrap();
    db.connection
        .pragma_update(None, "wal_autocheckpoint", 0)
        .unwrap();
    // Everything lives in the write-ahead log: the main file holds none of it.
    standard(&db, t0());
    let before = fs::read(&db.path).unwrap();
    let modified = fs::metadata(&db.path).unwrap().modified().unwrap();
    assert!(
        fs::metadata(format!("{}-wal", db.path.display()))
            .unwrap()
            .len()
            > 0
    );
    let mut monitor = fixture.monitor();
    assert_eq!(poll(&mut monitor, now()).len(), 1);
    assert_eq!(fs::read(&db.path).unwrap(), before);
    assert_eq!(
        fs::metadata(&db.path).unwrap().modified().unwrap(),
        modified
    );
}

#[test]
fn a_database_in_a_folder_with_spaces_is_read() {
    let fixture = Fixture::new();
    let root = fixture
        .dir
        .path()
        .join("My Data #1")
        .join("100% opencode data");
    let db = Database::create(root.join("opencode.db"));
    standard(&db, t0());
    assert!(OpenCodeMonitor::has_database(&root));
    assert_eq!(poll(&mut OpenCodeMonitor::new(root), now()).len(), 1);
    assert_eq!(
        read_only_uri(Path::new("/a b/opencode.db")).unwrap(),
        "file:///a%20b/opencode.db?mode=ro"
    );
}

#[test]
fn only_opencode_db_is_read_not_the_legacy_storage_folder_or_other_files() {
    let fixture = Fixture::new();
    assert!(!OpenCodeMonitor::has_database(&fixture.root()));
    let db = fixture.database();
    standard(&db, t0());
    // Other databases and the old JSON storage next to it carry turns that must be ignored.
    let other = Database::create(fixture.root().join("other.db"));
    standard(&other, t0());
    fs::create_dir_all(fixture.root().join("storage/message")).unwrap();
    fs::write(fixture.root().join("storage/message/x.json"), b"{}").unwrap();
    assert!(OpenCodeMonitor::has_database(&fixture.root()));
    assert_eq!(poll(&mut fixture.monitor(), now()).len(), 1);
    // A missing database is not an error.
    let mut empty = OpenCodeMonitor::new(fixture.dir.path().join("nothing"));
    assert!(poll(&mut empty, now()).is_empty());
}

#[test]
fn an_unreadable_database_is_retried_with_a_growing_delay() {
    let fixture = Fixture::new();
    fs::create_dir_all(fixture.root()).unwrap();
    let path = fixture.root().join("opencode.db");
    fs::write(&path, b"this is not a sqlite database at all").unwrap();
    let mut monitor = fixture.monitor();
    let start = now();
    assert!(poll(&mut monitor, start).is_empty());
    fs::remove_file(&path).unwrap();
    // A schema mismatch (no message table) is skipped too.
    Connection::open(&path)
        .unwrap()
        .execute_batch("CREATE TABLE session (id text)")
        .unwrap();
    assert!(poll(&mut monitor, start + Duration::seconds(11)).is_empty());
    fs::remove_file(&path).unwrap();
    let db = Database::create(path);
    standard(&db, t0());
    // The second failure waits 20 s: a changed database is not tried before then...
    assert!(poll(&mut monitor, start + Duration::seconds(20)).is_empty());
    // ...and is read once the delay is over.
    assert_eq!(poll(&mut monitor, start + Duration::seconds(32)).len(), 1);
}

#[test]
fn the_queries_select_only_listed_json_paths_and_never_the_part_table() {
    let source = include_str!("opencode_db.rs");
    assert!(!source.contains("FROM part"));
    assert!(!source.contains("JOIN part"));
    assert!(!source.contains("SELECT m.data"));
    // Every use of the data column is a json_extract or json_valid argument.
    for (index, _) in source.match_indices("m.data") {
        let before = &source[..index];
        assert!(
            before.ends_with("json_extract(") || before.ends_with("json_valid("),
            "m.data outside json_extract at {index}"
        );
    }
    for path in [
        "$.role",
        "$.parentID",
        "$.modelID",
        "$.providerID",
        "$.variant",
        "$.finish",
        "$.error.name",
        "$.time.created",
        "$.time.completed",
        "$.tokens.output",
        "$.tokens.reasoning",
        "$.tokens.input",
        "$.tokens.cache.read",
        "$.tokens.cache.write",
    ] {
        assert!(source.contains(&format!("'{path}'")), "{path}");
    }
    // Nothing else is extracted.
    assert_eq!(source.matches("json_extract(m.data").count(), 14);
}

// ---- bounded reads ---------------------------------------------------------------------------

fn read_all(db: &Database) -> crate::opencode_db::Read {
    crate::opencode_db::read_database(
        &db.path,
        crate::opencode_db::MessageScope::CreatedSince(0),
        true,
        &|_| false,
    )
    .unwrap()
}

fn assistant_data(extra: Value) -> String {
    let mut data = json!({
        "role": "assistant",
        "parentID": USER,
        "modelID": "claude-opus-4-6",
        "providerID": "anthropic",
        "finish": "stop",
        "time": {"created": 1_000, "completed": 5_000},
        "tokens": {"output": 100, "reasoning": 0, "input": 10, "cache": {"read": 0, "write": 0}}
    });
    for (key, value) in extra.as_object().unwrap() {
        data[key] = value.clone();
    }
    data.to_string()
}

#[test]
fn ids_and_values_over_their_limit_never_leave_sqlite() {
    let fixture = Fixture::new();
    let db = fixture.database();
    let long = |length: usize| "x".repeat(length);
    db.session(SESSION, None, VERSION);
    db.session(&long(513), None, VERSION);
    db.session("ses_long_parent", Some(&long(513)), VERSION);
    db.session("ses_long_version", Some(SESSION), &long(201));
    db.session("ses_edge", Some(&long(512)), &long(200));
    db.raw_message("msg_ok", SESSION, 1_000, 1_000, &assistant_data(json!({})));
    db.raw_message(
        &long(513),
        SESSION,
        1_000,
        1_000,
        &assistant_data(json!({})),
    );
    db.raw_message(
        &long(512),
        SESSION,
        1_000,
        1_000,
        &assistant_data(json!({})),
    );
    db.raw_message(
        "msg_session",
        &long(513),
        1_000,
        1_000,
        &assistant_data(json!({})),
    );
    db.raw_message(
        "msg_values",
        SESSION,
        1_000,
        1_000,
        &assistant_data(json!({
            "parentID": long(513),
            "modelID": long(201),
            "providerID": long(201),
            "variant": long(201),
            "finish": long(201),
        })),
    );
    db.raw_message(
        "msg_error",
        SESSION,
        1_000,
        1_000,
        &assistant_data(json!({"error": {"name": long(201)}})),
    );
    db.raw_message(
        "msg_unnamed_error",
        SESSION,
        1_000,
        1_000,
        &assistant_data(json!({"error": {"name": ""}})),
    );
    db.raw_message(
        "msg_count",
        SESSION,
        1_000,
        1_000,
        &assistant_data(json!({"tokens": {"output": long(201), "reasoning": 0}})),
    );
    db.raw_message(
        "msg_role",
        SESSION,
        1_000,
        1_000,
        &assistant_data(json!({"role": long(201)})),
    );

    let read = read_all(&db);
    let mut sessions: Vec<_> = read.sessions.iter().map(|s| s.id.as_str()).collect();
    sessions.sort();
    // A session with an over-long id or parent id is skipped; an over-long version is only empty.
    assert_eq!(
        sessions,
        ["ses_edge", "ses_long_version", "ses_primary"]
            .iter()
            .copied()
            .collect::<Vec<_>>()
    );
    let version = |id: &str| {
        read.sessions
            .iter()
            .find(|s| s.id == id)
            .unwrap()
            .version
            .len()
    };
    assert_eq!(version("ses_long_version"), 0);
    assert_eq!(version("ses_edge"), 200);
    assert_eq!(
        read.sessions
            .iter()
            .find(|s| s.id == "ses_edge")
            .unwrap()
            .parent_id,
        Some(long(512))
    );

    let message = |id: &str| read.messages.iter().find(|m| m.id == id);
    let assistant = |id: &str| match &message(id).unwrap().kind {
        crate::opencode_db::MessageKind::Assistant(assistant) => assistant.clone(),
        other => panic!("{other:?}"),
    };
    assert!(message("msg_ok").is_some());
    assert!(message(&long(512)).is_some());
    assert!(message(&long(513)).is_none());
    assert!(message("msg_session").is_none());
    // Over-long text is absent, an over-long error name still marks the message failed, and an
    // over-long count is invalid rather than zero.
    let values = assistant("msg_values");
    assert_eq!(values.parent_id, None);
    assert_eq!(values.model, None);
    assert_eq!(values.provider, None);
    assert_eq!(values.variant, None);
    assert_eq!(values.finish, None);
    assert!(!values.malformed);
    assert!(assistant("msg_error").failed);
    assert!(!assistant("msg_unnamed_error").failed);
    assert!(assistant("msg_count").malformed);
    assert!(message("msg_role").is_none());
}

#[test]
fn a_read_stops_at_its_byte_budget_and_keeps_the_newest_messages() {
    let fixture = Fixture::new();
    let db = fixture.database();
    db.session(SESSION, None, VERSION);
    for index in 0..100 {
        db.raw_message(
            &format!("msg_{index:03}"),
            SESSION,
            1_000 + index,
            1_000 + index,
            &assistant_data(json!({"modelID": format!("model-{index:03}")})),
        );
    }
    let read = |budget| {
        crate::opencode_db::read_database_within(
            &db.path,
            crate::opencode_db::MessageScope::CreatedSince(0),
            true,
            &|_| false,
            crate::opencode_db::Limits {
                bytes: budget,
                sessions: 1_000,
            },
        )
        .unwrap()
    };
    let all = read(usize::MAX);
    assert_eq!(all.messages.len(), 100);
    let per_message = all.bytes_read / 101;
    let bounded = read(per_message * 10);
    assert!((10..=12).contains(&bounded.messages.len()));
    assert!(bounded.bytes_read <= per_message * 12);
    // The newest are kept.
    assert_eq!(bounded.messages[0].id, "msg_099");
    assert_eq!(read(0).messages.len(), 0);
}

/// Many separate ancestry chains of three sessions, each with one message in the youngest.
fn chains(db: &Database, count: usize) {
    db.connection.execute_batch("BEGIN").unwrap();
    for index in 0..count {
        db.session(&format!("ses_root_{index}"), None, VERSION);
        db.session(
            &format!("ses_child_{index}"),
            Some(&format!("ses_root_{index}")),
            VERSION,
        );
        db.session(
            &format!("ses_leaf_{index}"),
            Some(&format!("ses_child_{index}")),
            VERSION,
        );
        db.raw_message(
            &format!("msg_{index}"),
            &format!("ses_leaf_{index}"),
            1_000 + index as i64,
            1_000 + index as i64,
            &assistant_data(json!({})),
        );
    }
    db.connection.execute_batch("COMMIT").unwrap();
}

fn read_ancestors(db: &Database, limits: crate::opencode_db::Limits) -> crate::opencode_db::Read {
    crate::opencode_db::read_database_within(
        &db.path,
        crate::opencode_db::MessageScope::CreatedSince(0),
        false,
        &|_| false,
        limits,
    )
    .unwrap()
}

#[test]
fn ancestor_lookups_find_every_chain_and_stay_within_the_read_limits() {
    use crate::opencode_db::Limits;
    let fixture = Fixture::new();
    let db = fixture.database();
    chains(&db, 3_000);
    let unlimited = Limits {
        bytes: usize::MAX,
        sessions: 100_000,
    };

    // Every session of every chain, over three rounds of lookups, each exactly once.
    let all = read_ancestors(&db, unlimited);
    assert_eq!(all.messages.len(), 3_000);
    let mut ids: Vec<&str> = all.sessions.iter().map(|s| s.id.as_str()).collect();
    ids.sort_unstable();
    ids.dedup();
    assert_eq!(ids.len(), 9_000);
    assert_eq!(all.sessions.len(), 9_000);

    // The session limit holds across rounds and chunks, not per query.
    let few = read_ancestors(
        &db,
        Limits {
            sessions: 1_000,
            ..unlimited
        },
    );
    assert_eq!(few.sessions.len(), 1_000);
    let none = read_ancestors(
        &db,
        Limits {
            sessions: 0,
            ..unlimited
        },
    );
    assert!(none.sessions.is_empty());

    // So does the byte budget, which the messages already used part of.
    let messages_only = read_ancestors(
        &db,
        Limits {
            sessions: 0,
            ..unlimited
        },
    )
    .bytes_read;
    for allowance in [0, 2_000, 50_000] {
        let read = read_ancestors(
            &db,
            Limits {
                bytes: messages_only + allowance,
                ..unlimited
            },
        );
        // One row past the allowance at most.
        assert!(
            read.bytes_read < messages_only + allowance + 300,
            "{allowance}"
        );
        assert_eq!(read.sessions.is_empty(), allowance == 0);
    }
    let full_bytes = all.bytes_read;
    assert!(full_bytes > messages_only + 50_000);
}

#[test]
fn an_ancestor_shared_by_many_sessions_is_asked_for_once() {
    use crate::opencode_db::Limits;
    let fixture = Fixture::new();
    let db = fixture.database();
    db.session("ses_shared", None, VERSION);
    db.connection.execute_batch("BEGIN").unwrap();
    for index in 0..500 {
        db.session(&format!("ses_leaf_{index}"), Some("ses_shared"), VERSION);
        db.raw_message(
            &format!("msg_{index}"),
            &format!("ses_leaf_{index}"),
            1_000 + index,
            1_000 + index,
            &assistant_data(json!({})),
        );
    }
    db.connection.execute_batch("COMMIT").unwrap();
    let read = read_ancestors(
        &db,
        Limits {
            bytes: usize::MAX,
            sessions: 100_000,
        },
    );
    assert_eq!(read.sessions.len(), 501);
    assert_eq!(
        read.sessions
            .iter()
            .filter(|s| s.id == "ses_shared")
            .count(),
        1
    );
}

#[cfg(unix)]
#[test]
fn a_database_or_log_that_is_a_fifo_is_not_opened() {
    use crate::tests::{make_fifo, within_seconds};
    let fixture = Fixture::new();
    fs::create_dir_all(fixture.root()).unwrap();
    make_fifo(&fixture.root().join("opencode.db"));
    let mut monitor = fixture.monitor();
    // The read fails like any unreadable database; the poll does not wait for a writer.
    let records = within_seconds(move || monitor.poll(now()).unwrap());
    assert!(records.is_empty());
    assert!(!OpenCodeMonitor::has_database(&fixture.root()));

    let fixture = Fixture::new();
    let db = fixture.database();
    standard(&db, t0());
    make_fifo(&crate::sqlite_read::wal_path(&db.path));
    let path = db.path.clone();
    let opened = within_seconds(move || crate::sqlite_read::open_read_only(&path).is_err());
    assert!(opened);
}

// ---- integration with the rest of the core ---------------------------------------------------

#[test]
fn source_monitor_polls_opencode_under_its_own_root_with_a_bounded_budget() {
    let fixture = Fixture::new();
    let db = fixture.database();
    standard(&db, t0());
    let empty = |name: &str| {
        let path = fixture.dir.path().join(name);
        fs::create_dir_all(&path).unwrap();
        path
    };
    let mut monitor = SourceMonitor::new(
        empty("codex"),
        empty("claude"),
        empty("grok"),
        empty("gemini"),
        fixture.root(),
    );
    assert_eq!(monitor.root("opencode"), Some(&fixture.root()));
    let turns = monitor.poll(now()).unwrap();
    assert_eq!(turns.len(), 1);
    assert_eq!(turns[0].client, OPENCODE_CLIENT);
    assert!(monitor.bytes_read_last_poll() <= SourceMonitor::MAX_POLL_BYTES);
    assert!(!monitor.had_source_error());
    // Changing the root starts a fresh monitor on the new folder.
    monitor.set_root("opencode", empty("nowhere")).unwrap();
    assert!(monitor.poll(now()).unwrap().is_empty());
    monitor.set_root("opencode", fixture.root()).unwrap();
    assert_eq!(monitor.poll(now()).unwrap().len(), 1);
}

#[test]
fn a_turn_re_emitted_with_its_delegated_total_replaces_the_pending_one_in_history_and_is_shared_once(
) {
    use crate::{History, SharingQueue};
    let fixture = Fixture::new();
    let db = fixture.database();
    let t0 = t0();
    standard(&db, t0);
    subagent(&db, t0);
    let running = Call::new("msg_c1", "msg_child_user")
        .session(CHILD)
        .running(t0 + 2_000)
        .tokens(0, 0);
    db.call(&running);
    let mut monitor = fixture.monitor();
    let mut history = History::default();
    let mut queue = SharingQueue::new();
    queue.enable(now() - Duration::hours(1));
    let first = poll(&mut monitor, now());
    history.merge(&first, now());
    queue.enqueue(&first, now());
    assert_eq!(history.records()[0].delegated_output_tokens, None);
    assert_eq!(queue.len(), 0);
    db.call(
        &running
            .span(t0 + 2_000, t0 + 9_000)
            .tokens(250, 0)
            .finish("stop"),
    );
    let second = poll(&mut monitor, now());
    history.merge(&second, now());
    queue.enqueue(&second, now());
    assert_eq!(history.records().len(), 1);
    assert_eq!(history.records()[0].delegated_output_tokens, Some(250));
    assert_eq!(queue.len(), 1);
}

// ---- event-driven polling ------------------------------------------------------------------------

fn changed(paths: &[PathBuf]) -> SourceChange {
    SourceChange {
        paths: paths.iter().cloned().collect(),
        must_rescan: false,
    }
}

#[test]
fn only_the_database_and_its_log_wake_a_poll() {
    let fixture = Fixture::new();
    let db = fixture.database();
    standard(&db, t0());
    let mut monitor = fixture.monitor();
    let at = now();
    assert_eq!(poll(&mut monitor, at).len(), 1);
    assert_eq!(monitor.next_poll_deadline(at), None);
    let root = fixture.root();
    // A report that changed nothing leaves nothing to poll for.
    assert!(!monitor.note_changes(&changed(&[db.path.clone()])));

    // The data folder also holds snapshots, tool output, logs and the old JSON storage, which change
    // constantly: none of them wakes a poll.
    let unrelated = [
        root.join("log/2026-10-06.log"),
        root.join("snapshot/abc/HEAD"),
        root.join("tool-output/tool_1"),
        root.join("storage/message/x.json"),
        root.join("auth.json"),
        root.join("opencode.db-shm"),
        root.join("other.db"),
        root.join("sub/opencode.db"),
    ];
    assert!(!monitor.note_changes(&changed(&unrelated)));
    assert_eq!(monitor.next_poll_deadline(at), None);

    db.user("msg_user_2", SESSION, t0() + 60_000);
    assert!(monitor.note_changes(&changed(&[db.path.clone()])));
    assert_eq!(monitor.next_poll_deadline(at), Some(at));
    assert!(poll(&mut monitor, at).is_empty());
    assert_eq!(monitor.next_poll_deadline(at), None);
    // A write to the log counts too.
    db.user("msg_user_3", SESSION, t0() + 61_000);
    let wal = PathBuf::from(format!("{}-wal", db.path.display()));
    assert!(monitor.note_changes(&changed(&[wal])));
    assert_eq!(monitor.next_poll_deadline(at), Some(at));
    poll(&mut monitor, at);
    // A lost event is answered by a poll.
    assert!(monitor.note_changes(&SourceChange {
        paths: Default::default(),
        must_rescan: true,
    }));
}

#[test]
fn deadlines_are_a_waiting_read_the_retry_time_and_the_delegation_settle() {
    let fixture = Fixture::new();
    let db = fixture.database();
    let t0 = t0();
    standard(&db, t0);
    subagent(&db, t0);
    db.call(
        &Call::new("msg_c1", "msg_child_user")
            .session(CHILD)
            .running(t0 + 2_000)
            .tokens(0, 0),
    );
    let mut monitor = fixture.monitor();
    let at = now();
    // Nothing read yet, but the database exists and is stat-ed by the poll.
    assert_eq!(poll(&mut monitor, at)[0].delegated_output_tokens, None);
    // The turn waits for unfinished subagent work: its wait ends 30 minutes after the turn did.
    let completed = DateTime::<Utc>::from_timestamp_millis(t0 + 16_000).unwrap();
    assert_eq!(
        monitor.next_poll_deadline(at),
        Some(completed + Duration::minutes(30))
    );
    // A changed database comes first.
    db.user("msg_user_2", SESSION, t0 + 60_000);
    assert!(monitor.note_changes(&changed(&[db.path.clone()])));
    assert_eq!(monitor.next_poll_deadline(at), Some(at));
    poll(&mut monitor, at);
    // The settle is final after the wait.
    let settled = poll(&mut monitor, completed + Duration::minutes(31));
    assert_eq!(settled.len(), 1);
    assert_eq!(
        monitor.next_poll_deadline(completed + Duration::minutes(31)),
        None
    );

    // An unreadable database is retried with a growing delay.
    let broken = Fixture::new();
    fs::create_dir_all(broken.root()).unwrap();
    let path = broken.root().join("opencode.db");
    fs::write(&path, b"this is not a sqlite database at all").unwrap();
    let mut monitor = broken.monitor();
    assert!(poll(&mut monitor, at).is_empty());
    assert_eq!(
        monitor.next_poll_deadline(at),
        Some(at + Duration::seconds(10))
    );
    let later = at + Duration::seconds(11);
    assert_eq!(monitor.next_poll_deadline(later), Some(later));
    assert!(poll(&mut monitor, later).is_empty());
    assert_eq!(
        monitor.next_poll_deadline(later),
        Some(later + Duration::seconds(20))
    );
    // A missing database has nothing to wait for.
    let mut nothing = OpenCodeMonitor::new(broken.dir.path().join("none"));
    assert!(poll(&mut nothing, at).is_empty());
    assert_eq!(nothing.next_poll_deadline(at), None);
    assert!(!nothing.root_exists());
}

#[test]
fn source_monitor_wakes_on_the_opencode_database_only_and_watches_its_folder_shallowly() {
    let fixture = Fixture::new();
    let db = fixture.database();
    standard(&db, t0());
    let empty = |name: &str| {
        let path = fixture.dir.path().join(name);
        fs::create_dir_all(&path).unwrap();
        path
    };
    let mut monitor = SourceMonitor::new(
        empty("codex"),
        empty("claude"),
        empty("grok"),
        empty("gemini"),
        fixture.root(),
    );
    let at = now();
    assert_eq!(monitor.poll(at).unwrap().len(), 1);
    assert_eq!(monitor.next_poll_deadline(at), None);
    assert!(!monitor.note_changes(&changed(&[
        fixture.root().join("log/today.log"),
        fixture
            .dir
            .path()
            .join("gemini/antigravity/conversations/a.db"),
    ])));
    db.user("msg_user_2", SESSION, t0() + 60_000);
    assert!(monitor.note_changes(&changed(&[db.path.clone()])));
    assert_eq!(monitor.next_poll_deadline(at), Some(at));
    // The data folder is watched without its snapshot, tool-output and log subfolders.
    let folders = monitor.watch_folders("opencode");
    assert_eq!(folders.len(), 1);
    assert_eq!(folders[0].path, fixture.root());
    assert!(folders[0].exists && !folders[0].recursive);
    assert_eq!(monitor.root_exists("opencode"), Some(true));
}
