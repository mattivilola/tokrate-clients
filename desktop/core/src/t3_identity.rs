//! Metadata-only attribution of native Claude transcripts owned by T3 Code.
//!
//! The T3 state database is a private implementation detail. This reader selects only the native
//! session UUID and provider-turn timestamps that establish an association. It never selects or
//! decodes the provider-thread JSON payload itself.

use crate::sqlite_read::{open_read_only, retry_delay, DatabaseSignature};
use crate::ToolSurface;
use chrono::{DateTime, Duration, Utc};
use rusqlite::params;
use std::collections::HashMap;
use std::path::Path;
use std::sync::RwLock;
use uuid::Uuid;

const STATE_DATABASE: &str = "statev2.sqlite";
const MAX_PROVIDER_TURNS: usize = 20_000;
const STATE_RETENTION_DAYS: i64 = 7;
const FINISHED_TURN_MAX_HOURS: i64 = 24;
const ACTIVE_TURN_MAX_AGE_HOURS: i64 = 1;
const BOUNDARY_TOLERANCE_SECONDS: i64 = 2;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
struct ProviderWindow {
    started_at: DateTime<Utc>,
    completed_at: Option<DateTime<Utc>>,
}

#[derive(Default)]
struct IndexState {
    signature: Option<DatabaseSignature>,
    retry_at: Option<DateTime<Utc>>,
    failures: u32,
    initialized: bool,
    dirty: bool,
    windows: HashMap<Uuid, Vec<ProviderWindow>>,
}

/// Shared read-only attribution index. A host refreshes it by database signature before polling
/// Claude; parsers hold only this in-memory metadata index while consuming transcripts.
#[derive(Default)]
pub(crate) struct T3ClaudeIdentityIndex {
    state: RwLock<IndexState>,
}

impl T3ClaudeIdentityIndex {
    /// Reads changed `statev2.sqlite` metadata only. The database and WAL are never modified.
    pub(crate) fn refresh(&self, state_root: &Path, now: DateTime<Utc>) {
        let path = state_root.join(STATE_DATABASE);
        let signature = DatabaseSignature::of(&path);
        {
            let state = self.state.read().unwrap_or_else(|error| error.into_inner());
            if state.initialized
                && !state.dirty
                && signature == state.signature
                && state.retry_at.is_none_or(|retry_at| retry_at > now)
            {
                return;
            }
            if state.retry_at.is_some_and(|retry_at| retry_at > now) {
                return;
            }
        }

        let result = signature.and_then(|signature| {
            read_provider_windows(&path, now)
                .ok()
                .map(|windows| (signature, windows))
        });
        let mut state = self
            .state
            .write()
            .unwrap_or_else(|error| error.into_inner());
        match result {
            Some((signature, windows)) => {
                state.signature = Some(signature);
                state.retry_at = None;
                state.failures = 0;
                state.initialized = true;
                state.dirty = false;
                state.windows = windows;
            }
            None => {
                // A changed but unreadable index must not keep making a stale T3 association.
                state.signature = signature;
                state.windows.clear();
                state.failures = state.failures.saturating_add(1);
                state.retry_at = Some(now + retry_delay(state.failures));
                state.initialized = true;
                state.dirty = false;
            }
        }
    }

    pub(crate) fn invalidate(&self) {
        let mut state = self
            .state
            .write()
            .unwrap_or_else(|error| error.into_inner());
        state.dirty = true;
        state.retry_at = None;
    }

    /// True only for an SDK transcript whose complete native timestamp span belongs to exactly
    /// one strong Claude Agent provider turn. When `end` is absent, the caller may supply one
    /// timestamp for an API outcome; completed transcript turns always require both endpoints.
    pub(crate) fn is_t3_activity(
        &self,
        native_session_id: Option<&str>,
        start: Option<DateTime<Utc>>,
        end: Option<DateTime<Utc>>,
        surface: Option<ToolSurface>,
        now: DateTime<Utc>,
    ) -> bool {
        if surface != Some(ToolSurface::Sdk) {
            return false;
        }
        let (Some(native_session_id), Some(start)) = (native_session_id, start) else {
            return false;
        };
        let Ok(session_id) = Uuid::parse_str(native_session_id) else {
            return false;
        };
        let state = self.state.read().unwrap_or_else(|error| error.into_inner());
        let Some(windows) = state.windows.get(&session_id) else {
            return false;
        };
        let matching = windows
            .iter()
            .filter(|window| window_is_recent(**window, now))
            .filter(|window| contains_activity(**window, start, end, now))
            .count();
        matching == 1
    }
}

fn window_is_recent(window: ProviderWindow, now: DateTime<Utc>) -> bool {
    match window.completed_at {
        Some(completed_at) => {
            completed_at <= now + Duration::seconds(BOUNDARY_TOLERANCE_SECONDS)
                && window.started_at >= now - Duration::days(STATE_RETENTION_DAYS)
        }
        None => {
            window.started_at <= now + Duration::seconds(BOUNDARY_TOLERANCE_SECONDS)
                && window.started_at >= now - Duration::hours(ACTIVE_TURN_MAX_AGE_HOURS)
        }
    }
}

fn contains_activity(
    window: ProviderWindow,
    start: DateTime<Utc>,
    end: Option<DateTime<Utc>>,
    now: DateTime<Utc>,
) -> bool {
    let tolerance = Duration::seconds(BOUNDARY_TOLERANCE_SECONDS);
    let lower = window.started_at - tolerance;
    let upper = window.completed_at.unwrap_or(now).min(now + tolerance) + tolerance;
    if start < lower || start > upper {
        return false;
    }
    end.is_none_or(|end| end >= lower && end <= upper)
}

fn read_provider_windows(
    path: &Path,
    now: DateTime<Utc>,
) -> rusqlite::Result<HashMap<Uuid, Vec<ProviderWindow>>> {
    let connection = open_read_only(path)?;
    let cutoff = (now - Duration::days(STATE_RETENTION_DAYS)).to_rfc3339();
    // Do not select payload_json: the two eligibility checks happen in SQLite, and only the
    // native session reference (plus the joined provider-turn interval) crosses the boundary.
    let mut statement = connection.prepare(
        "SELECT CASE WHEN typeof(json_extract(t.payload_json, '$.nativeThreadRef.nativeId')) = 'text' \
         AND length(json_extract(t.payload_json, '$.nativeThreadRef.nativeId')) <= 64 \
         THEN json_extract(t.payload_json, '$.nativeThreadRef.nativeId') END, \
         CASE WHEN typeof(p.started_at) = 'text' AND length(p.started_at) <= 64 THEN p.started_at END, \
         CASE WHEN p.completed_at IS NULL THEN NULL \
         WHEN typeof(p.completed_at) = 'text' AND length(p.completed_at) <= 64 THEN p.completed_at \
         ELSE '' END \
         FROM orchestration_v2_projection_provider_threads AS t \
         JOIN orchestration_v2_projection_provider_turns AS p \
           ON p.provider_thread_id = t.provider_thread_id \
         WHERE json_extract(t.payload_json, '$.nativeThreadRef.driver') = 'claudeAgent' \
           AND json_extract(t.payload_json, '$.nativeThreadRef.strength') = 'strong' \
           AND p.started_at >= ?1 \
         ORDER BY p.started_at DESC LIMIT ?2",
    )?;
    let rows = statement.query_map(params![cutoff, MAX_PROVIDER_TURNS as i64 + 1], |row| {
        Ok((
            row.get::<_, Option<String>>(0)?,
            row.get::<_, Option<String>>(1)?,
            row.get::<_, Option<String>>(2)?,
        ))
    })?;
    let mut windows = HashMap::<Uuid, Vec<ProviderWindow>>::new();
    let mut row_count = 0;
    for row in rows {
        row_count += 1;
        if row_count > MAX_PROVIDER_TURNS {
            return Err(rusqlite::Error::InvalidQuery);
        }
        let (Some(native_id), Some(start), completed) = row? else {
            continue;
        };
        let (Ok(native_id), Some(started_at)) =
            (Uuid::parse_str(&native_id), parse_timestamp(&start))
        else {
            continue;
        };
        let completed_at = match completed {
            None => None,
            Some(value) => match parse_timestamp(&value) {
                Some(completed_at) => Some(completed_at),
                None => continue,
            },
        };
        let tolerance = Duration::seconds(BOUNDARY_TOLERANCE_SECONDS);
        if started_at > now + tolerance || started_at < now - Duration::days(STATE_RETENTION_DAYS) {
            continue;
        }
        if let Some(completed_at) = completed_at {
            if completed_at < started_at
                || completed_at - started_at > Duration::hours(FINISHED_TURN_MAX_HOURS)
                || completed_at > now + tolerance
            {
                continue;
            }
        } else if now - started_at > Duration::hours(ACTIVE_TURN_MAX_AGE_HOURS) {
            continue;
        }
        windows.entry(native_id).or_default().push(ProviderWindow {
            started_at,
            completed_at,
        });
    }
    Ok(windows)
}

fn parse_timestamp(value: &str) -> Option<DateTime<Utc>> {
    DateTime::parse_from_rfc3339(value)
        .ok()
        .map(|value| value.with_timezone(&Utc))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::claude_parser::ClaudeTranscriptParser;
    use crate::model::{CLAUDE_CLIENT, T3_CODE_CLIENT};
    use crate::parser::JsonlEventParser;
    use chrono::SecondsFormat;
    use rusqlite::Connection;
    use serde_json::json;
    use std::path::Path;
    use std::sync::Arc;
    use tempfile::TempDir;

    struct StateFixture {
        dir: TempDir,
        connection: Connection,
    }

    impl StateFixture {
        fn new() -> Self {
            let dir = tempfile::tempdir().unwrap();
            let connection = Connection::open(dir.path().join(STATE_DATABASE)).unwrap();
            connection
                .execute_batch(
                    "CREATE TABLE orchestration_v2_projection_provider_threads(\
                        provider_thread_id TEXT PRIMARY KEY, payload_json TEXT NOT NULL\
                     );\
                     CREATE TABLE orchestration_v2_projection_provider_turns(\
                        provider_turn_id TEXT PRIMARY KEY, provider_thread_id TEXT NOT NULL,\
                        started_at TEXT NOT NULL, completed_at TEXT\
                     );",
                )
                .unwrap();
            Self { dir, connection }
        }

        fn add_window(
            &self,
            thread_id: &str,
            session_id: &str,
            driver: &str,
            strength: &str,
            started_at: DateTime<Utc>,
            completed_at: Option<DateTime<Utc>>,
        ) {
            let payload = serde_json::to_string(&json!({
                "nativeThreadRef": {
                    "nativeId": session_id,
                    "driver": driver,
                    "strength": strength
                },
                "title": "PRIVATE_T3_TITLE_SENTINEL",
                "prompt": "PRIVATE_T3_PROMPT_SENTINEL"
            }))
            .unwrap();
            self.connection
                .execute(
                    "INSERT INTO orchestration_v2_projection_provider_threads\
                     (provider_thread_id, payload_json) VALUES (?1, ?2)",
                    params![thread_id, payload],
                )
                .unwrap();
            self.connection
                .execute(
                    "INSERT INTO orchestration_v2_projection_provider_turns\
                     (provider_turn_id, provider_thread_id, started_at, completed_at)\
                     VALUES (?1, ?2, ?3, ?4)",
                    params![
                        format!("provider-{thread_id}"),
                        thread_id,
                        started_at.to_rfc3339_opts(SecondsFormat::Millis, true),
                        completed_at
                            .map(|value| value.to_rfc3339_opts(SecondsFormat::Millis, true)),
                    ],
                )
                .unwrap();
        }

        fn root(&self) -> &Path {
            self.dir.path()
        }
    }

    fn record_time(at: DateTime<Utc>) -> String {
        at.to_rfc3339_opts(SecondsFormat::Millis, true)
    }

    fn transcript_record(
        kind: &str,
        session: &str,
        at: DateTime<Utc>,
        entrypoint: &str,
    ) -> Vec<u8> {
        let common = json!({
            "type": kind,
            "timestamp": record_time(at),
            "isSidechain": false,
            "userType": "external",
            "version": "2.1.0",
            "uuid": format!("{kind}-record-{at}"),
            "sessionId": session,
            "entrypoint": entrypoint,
        });
        let mut record = common;
        if kind == "user" {
            record["message"] = json!({
                "id": "user-message",
                "role": "user",
                "content": "PRIVATE_TRANSCRIPT_PROMPT_SENTINEL"
            });
        } else {
            record["message"] = json!({
                "id": "msg_01ABCDEFGHJKLMNPQRSTUVwx",
                "role": "assistant",
                "model": "claude-sonnet-4-5",
                "stop_reason": "end_turn",
                "content": [{"type":"text", "text":"PRIVATE_TRANSCRIPT_RESPONSE_SENTINEL"}],
                "usage": {"output_tokens": 200},
                "effort": "high"
            });
            record["requestId"] = json!("req_011CPabcdefghijklmnopqrstuv");
        }
        serde_json::to_vec(&record).unwrap()
    }

    #[test]
    fn strong_claude_agent_windows_match_only_one_complete_sdk_span() {
        let fixture = StateFixture::new();
        let now = Utc::now();
        let session = Uuid::new_v4().to_string();
        let start = now - Duration::minutes(10);
        let end = start + Duration::seconds(20);
        fixture.add_window(
            "strong-agent",
            &session,
            "claudeAgent",
            "strong",
            start,
            Some(end),
        );
        fixture.add_window(
            "weak-agent",
            &Uuid::new_v4().to_string(),
            "claudeAgent",
            "weak",
            start,
            Some(end),
        );
        fixture.add_window(
            "other-driver",
            &Uuid::new_v4().to_string(),
            "sdkTs",
            "strong",
            start,
            Some(end),
        );
        fixture.add_window(
            "invalid-uuid",
            "private-session-id",
            "claudeAgent",
            "strong",
            start,
            Some(end),
        );
        let root = fixture.root().to_path_buf();
        drop(fixture.connection);

        let index = T3ClaudeIdentityIndex::default();
        index.refresh(&root, now);
        assert!(index.is_t3_activity(
            Some(&session),
            Some(start + Duration::seconds(1)),
            Some(end - Duration::seconds(1)),
            Some(ToolSurface::Sdk),
            now,
        ));
        assert!(!index.is_t3_activity(
            Some(&session),
            Some(start),
            Some(end),
            Some(ToolSurface::Cli),
            now,
        ));
        assert!(!index.is_t3_activity(
            Some("private-session-id"),
            Some(start),
            Some(end),
            Some(ToolSurface::Sdk),
            now,
        ));
    }

    #[test]
    fn active_windows_are_bounded_and_overlapping_windows_are_ambiguous() {
        let fixture = StateFixture::new();
        let now = Utc::now();
        let active_session = Uuid::new_v4().to_string();
        let active_start = now - Duration::minutes(30);
        fixture.add_window(
            "active",
            &active_session,
            "claudeAgent",
            "strong",
            active_start,
            None,
        );
        let ambiguous_session = Uuid::new_v4().to_string();
        let finished_start = now - Duration::minutes(12);
        let finished_end = finished_start + Duration::seconds(20);
        fixture.add_window(
            "finished-a",
            &ambiguous_session,
            "claudeAgent",
            "strong",
            finished_start,
            Some(finished_end),
        );
        fixture.add_window(
            "finished-b",
            &ambiguous_session,
            "claudeAgent",
            "strong",
            finished_start,
            Some(finished_end),
        );
        let stale_session = Uuid::new_v4().to_string();
        fixture.add_window(
            "stale-active",
            &stale_session,
            "claudeAgent",
            "strong",
            now - Duration::hours(2),
            None,
        );
        let too_long_session = Uuid::new_v4().to_string();
        fixture.add_window(
            "too-long",
            &too_long_session,
            "claudeAgent",
            "strong",
            now - Duration::hours(26),
            Some(now - Duration::hours(1)),
        );
        let root = fixture.root().to_path_buf();
        drop(fixture.connection);

        let index = T3ClaudeIdentityIndex::default();
        index.refresh(&root, now);
        assert!(index.is_t3_activity(
            Some(&active_session),
            Some(active_start + Duration::seconds(2)),
            Some(now - Duration::seconds(2)),
            Some(ToolSurface::Sdk),
            now,
        ));
        assert!(!index.is_t3_activity(
            Some(&ambiguous_session),
            Some(finished_start),
            Some(finished_end),
            Some(ToolSurface::Sdk),
            now,
        ));
        assert!(!index.is_t3_activity(
            Some(&stale_session),
            Some(now - Duration::minutes(59)),
            Some(now - Duration::minutes(58)),
            Some(ToolSurface::Sdk),
            now,
        ));
        assert!(!index.is_t3_activity(
            Some(&too_long_session),
            Some(now - Duration::hours(25)),
            Some(now - Duration::hours(3)),
            Some(ToolSurface::Sdk),
            now,
        ));
    }

    #[test]
    fn sdk_turns_are_attributed_without_changing_native_identity_or_leaking_metadata() {
        let fixture = StateFixture::new();
        let now = Utc::now();
        let session = Uuid::new_v4().to_string();
        let start = now - Duration::seconds(30);
        let end = now - Duration::seconds(20);
        fixture.add_window(
            "parser-attribution",
            &session,
            "claudeAgent",
            "strong",
            start,
            Some(end),
        );
        let root = fixture.root().to_path_buf();
        drop(fixture.connection);
        let index = Arc::new(T3ClaudeIdentityIndex::default());
        index.refresh(&root, now);

        let prompt = transcript_record("user", &session, start + Duration::seconds(1), "sdk-ts");
        let response = transcript_record("assistant", &session, end, "sdk-ts");
        let path = Path::new("native-file-identity.jsonl");
        let mut t3_parser = ClaudeTranscriptParser::for_path_with_t3_identity(path, Some(index));
        t3_parser.consume_settled(&prompt);
        let t3_turn = t3_parser.consume_settled(&response).unwrap();
        let t3_responses = t3_parser.take_responses();
        let t3_outcomes = t3_parser.take_outcomes();
        let mut native_parser = ClaudeTranscriptParser::for_path(path);
        native_parser.consume_settled(&prompt);
        let native_turn = native_parser.consume_settled(&response).unwrap();
        let native_responses = native_parser.take_responses();
        let native_outcomes = native_parser.take_outcomes();

        assert_eq!(t3_turn.client, T3_CODE_CLIENT);
        assert_eq!(t3_turn.surface, Some(ToolSurface::Sdk));
        assert_eq!(t3_turn.id, native_turn.id);
        assert_eq!(native_turn.client, CLAUDE_CLIENT);
        assert_eq!(t3_turn.parser_version, native_turn.parser_version);
        assert_eq!(t3_turn.metric_version, native_turn.metric_version);
        assert_eq!(t3_responses.len(), 1);
        assert_eq!(t3_responses[0].client, T3_CODE_CLIENT);
        assert_eq!(t3_responses[0].id, native_responses[0].id);
        assert_eq!(t3_outcomes.len(), 1);
        assert_eq!(t3_outcomes[0].client, T3_CODE_CLIENT);
        assert_eq!(t3_outcomes[0].dedupe_key, native_outcomes[0].dedupe_key);
        let serialized = serde_json::to_string(&t3_turn).unwrap();
        for private in [
            "PRIVATE_T3_TITLE_SENTINEL",
            "PRIVATE_T3_PROMPT_SENTINEL",
            "PRIVATE_TRANSCRIPT_PROMPT_SENTINEL",
            "PRIVATE_TRANSCRIPT_RESPONSE_SENTINEL",
            &session,
        ] {
            assert!(!serialized.contains(private));
        }
    }
}
