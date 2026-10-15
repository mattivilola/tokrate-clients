use crate::{
    config::{self, Paths, Settings},
    credentials,
    runtime::Host,
};
use chrono::{Duration, Utc};
use serde_json::json;
use std::{fs, path::Path};
use tempfile::TempDir;
use tokrate_core::TurnMetric;
use zeroize::Zeroizing;

fn configured(share: bool) -> (TempDir, Paths, Settings) {
    let dir = tempfile::tempdir().unwrap();
    let paths = Paths {
        config: dir.path().join("config"),
        data: dir.path().join("data"),
    };
    config::setup(&paths, Some(share)).unwrap();
    let mut settings = paths.load().unwrap();
    settings.codex = dir.path().join("codex");
    settings.claude = dir.path().join("claude");
    settings.grok = dir.path().join("grok");
    settings.antigravity = dir.path().join("antigravity");
    settings.opencode = dir.path().join("opencode");
    settings.kimi = dir.path().join("kimi");
    settings.kimi_desktop = dir.path().join("kimi-desktop");
    settings.t3 = dir.path().join("t3");
    fs::write(
        paths.config.join("settings.json"),
        serde_json::to_vec(&settings).unwrap(),
    )
    .unwrap();
    (dir, paths, settings)
}

fn metric(id: &str, at: chrono::DateTime<Utc>) -> TurnMetric {
    let mut m = TurnMetric::new(
        id.into(),
        at,
        Some("gpt-test".into()),
        200,
        10.0,
        Some(0.5),
        20.0,
        None,
        None,
        None,
        None,
        None,
        None,
    );
    m.client = tokrate_core::CODEX_CLIENT.into();
    m.parser_version = tokrate_core::CODEX_PARSER_VERSION.into();
    m.metric_version = tokrate_core::CODEX_METRIC_VERSION.into();
    m.provider = Some("openai".into());
    m.source_kind = Some("primary".into());
    m.delegated_output_tokens = Some(0);
    m
}

#[test]
fn off_and_obsolete_consent_never_call_identity_loader() {
    let (_dir, paths, settings) = configured(false);
    let now = Utc::now();
    let mut host = Host::new(&paths, &settings, true, now);
    assert!(host
        .activate(&paths, |_| panic!("OFF read a credential"), now)
        .is_none());
    assert!(credentials::load(&paths).is_err());
    fs::write(
        paths.consent(),
        br#"{"notice_version":"obsolete","accepted_at":"2026-01-01T00:00:00Z"}"#,
    )
    .unwrap();
    assert!(host
        .activate(
            &paths,
            |_| panic!("Obsolete consent read a credential"),
            now
        )
        .is_none());
    fs::write(paths.consent(), b"broken").unwrap();
    assert!(!paths.consent_valid());
    // Even accepted consent cannot grant credentials to a local-only runtime.
    config::setup(&paths, Some(true)).unwrap();
    let mut local = Host::new(&paths, &settings, false, now);
    assert!(local
        .activate(&paths, |_| panic!("Local runtime read a credential"), now)
        .is_none());
}

#[test]
fn single_writer_lock_and_custom_roots_survive_setup() {
    let (_dir, paths, settings) = configured(false);
    let lock = paths.lock().unwrap();
    assert!(paths.lock().is_err());
    assert!(config::setup(&paths, Some(true)).is_err());
    drop(lock);
    config::setup(&paths, Some(true)).unwrap();
    assert_eq!(paths.load().unwrap().codex, settings.codex);
    assert!(paths.consent_valid());
    config::setup(&paths, Some(false)).unwrap();
    assert!(!paths.consent_valid());
}

#[test]
fn restart_retry_and_withdrawal_have_future_only_cutoffs() {
    let (_dir, paths, settings) = configured(true);
    let now = Utc::now();
    let mut host = Host::new(&paths, &settings, true, now);
    host.activate(&paths, |_| Ok(Zeroizing::new([7; 32])), now)
        .unwrap();
    host.queue.enqueue(
        &[
            metric("old", now - Duration::seconds(1)),
            metric("new", now),
        ],
        now,
    );
    assert_eq!(host.queue.len(), 1);
    let later = now + Duration::minutes(1);
    host.deactivate();
    assert!(host.queue.is_empty());
    host.activate(&paths, |_| Ok(Zeroizing::new([7; 32])), later)
        .unwrap();
    host.queue.enqueue(&[metric("new", now)], later);
    assert!(host.queue.is_empty());
    let mut restarted = Host::new(&paths, &settings, true, later);
    restarted
        .activate(&paths, |_| Ok(Zeroizing::new([7; 32])), later)
        .unwrap();
    restarted.queue.enqueue(&[metric("new", now)], later);
    assert!(restarted.queue.is_empty());
}

#[test]
fn upload_results_retry_drop_ack_and_stop_without_regenerating() {
    let (_dir, paths, settings) = configured(true);
    let now = Utc::now();
    let mut host = Host::new(&paths, &settings, true, now);
    host.activate(&paths, |_| Ok(Zeroizing::new([7; 32])), now)
        .unwrap();
    host.queue.enqueue(&[metric("new", now)], now);
    let due = now + Duration::minutes(20);
    let batch = host.queue.upload_batch(due);
    assert_eq!(batch.samples.len(), 1);
    host.finish_upload(Some(503), &batch, due);
    assert_eq!(host.queue.len(), 1);
    host.finish_upload(None, &batch, due);
    assert_eq!(host.queue.len(), 1);
    host.finish_upload(Some(201), &batch, due);
    assert!(host.queue.is_empty());
    assert_eq!(host.status.uploaded_samples, 1);
    host.queue.enqueue(&[metric("next", due)], due);
    let next = host.queue.upload_batch(due + Duration::minutes(20));
    assert!(!next.is_empty());
    host.finish_upload(Some(422), &next, due);
    assert!(host.queue.is_empty());
    assert!(!host.finish_upload(Some(426), &next, due));
    assert!(!host.status.sharing_active);
}

fn fixture(root: &Path, start: chrono::DateTime<Utc>) {
    fs::create_dir_all(root).unwrap();
    let end = start + Duration::seconds(10);
    let event = |kind: &str, payload: serde_json::Value, at: chrono::DateTime<Utc>| {
        json!({
            "type": kind, "timestamp": at.to_rfc3339(), "payload": payload,
        })
    };
    let events = [
        event(
            "session_meta",
            json!({"id":"SENSITIVE-SESSION", "source":"cli", "model_provider":"openai", "cli_version":"0.159.2"}),
            start,
        ),
        event(
            "event_msg",
            json!({"type":"task_started", "turn_id":"SENSITIVE-TURN", "started_at":start.to_rfc3339()}),
            start,
        ),
        event(
            "turn_context",
            json!({"turn_id":"SENSITIVE-TURN", "model":"gpt-test", "effort":"high"}),
            start,
        ),
        event(
            "token_usage_record",
            json!({"turn_id":"SENSITIVE-TURN", "turn_token_usage":{"output_tokens":200}}),
            end,
        ),
        event(
            "event_msg",
            json!({"type":"task_complete", "turn_id":"SENSITIVE-TURN", "started_at":start.to_rfc3339(), "completed_at":end.to_rfc3339(), "last_agent_message":"SENSITIVE-CONTENT"}),
            end,
        ),
    ];
    fs::write(
        root.join("rollout.jsonl"),
        events.iter().map(|e| format!("{e}\n")).collect::<String>(),
    )
    .unwrap();
}

#[test]
fn real_core_poll_saves_only_metrics_and_resumes_checkpoints() {
    let (_dir, paths, settings) = configured(false);
    let now = Utc::now();
    fixture(&settings.codex, now - Duration::seconds(60));
    let mut host = Host::new(&paths, &settings, false, now);
    host.poll(now).unwrap();
    host.poll(now + Duration::seconds(60)).unwrap();
    assert_eq!(host.history.records().len(), 1);
    assert!(host.queue.is_empty());
    host.history.save(paths.data.join("history.json")).unwrap();
    let bytes = fs::read_to_string(paths.data.join("history.json")).unwrap();
    assert!(!bytes.contains("SENSITIVE"));
    assert!(!bytes.contains(&settings.codex.to_string_lossy().into_owned()));
    let mut restarted = Host::new(&paths, &settings, false, now + Duration::seconds(120));
    restarted.poll(now + Duration::seconds(120)).unwrap();
    assert_eq!(restarted.history.records().len(), 1);
}

#[test]
fn credential_failure_keeps_local_monitoring_and_history_corruption_is_preserved() {
    let (_dir, paths, settings) = configured(true);
    fs::write(paths.data.join("history.json"), b"unreadable old state").unwrap();
    let now = Utc::now();
    let mut host = Host::new(&paths, &settings, true, now);
    assert!(host
        .activate(&paths, |_| Err("bad credential".into()), now)
        .is_none());
    host.poll(now).unwrap();
    assert!(host.status.monitoring);
    assert!(!host.status.sharing_active);
    assert!(host.status.history_error);
    assert_eq!(
        fs::read(paths.data.join("history.json")).unwrap(),
        b"unreadable old state"
    );
}

#[test]
fn lock_and_small_files_reject_symlinks() {
    let (dir, paths, _) = configured(true);
    let target = dir.path().join("unrelated");
    fs::write(&target, b"preserve me").unwrap();
    fs::remove_file(paths.data.join("daemon.lock")).unwrap();
    std::os::unix::fs::symlink(&target, paths.data.join("daemon.lock")).unwrap();
    assert!(paths.lock().is_err());
    assert_eq!(fs::read(&target).unwrap(), b"preserve me");
    fs::remove_file(paths.consent()).unwrap();
    std::os::unix::fs::symlink(&target, paths.consent()).unwrap();
    assert!(!paths.consent_valid());
}

#[tokio::test]
async fn real_http_transport_sends_exact_signed_body_and_never_follows_redirects() {
    use std::io::{Read, Write};
    let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
    listener.set_nonblocking(true).unwrap();
    let address = listener.local_addr().unwrap();
    let now = Utc::now();
    let sample = tokrate_core::SharedSample::from_metric(
        &metric("local-private-id", now),
        "00000000-0000-4000-8000-000000000001".parse().unwrap(),
    )
    .unwrap();
    let signed = tokrate_core::signed_request(&[sample], &[], &[9; 32], now).unwrap();
    let body = signed.body.clone();
    let expected_key = signed.public_key.clone();
    let expected_signature = signed.signature.clone();
    let server = std::thread::spawn(move || {
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(5);
        let mut connection = loop {
            match listener.accept() {
                Ok((connection, _)) => break connection,
                Err(e)
                    if e.kind() == std::io::ErrorKind::WouldBlock
                        && std::time::Instant::now() < deadline =>
                {
                    std::thread::sleep(std::time::Duration::from_millis(10))
                }
                Err(e) => panic!("Local mock server: {e}"),
            }
        };
        connection
            .set_read_timeout(Some(std::time::Duration::from_secs(5)))
            .unwrap();
        let mut received = Vec::new();
        let (headers, actual_body) = loop {
            let mut buffer = [0u8; 4096];
            let count = connection.read(&mut buffer).unwrap();
            assert_ne!(count, 0);
            received.extend_from_slice(&buffer[..count]);
            assert!(received.len() <= 100_000);
            if let Some(split) = received.windows(4).position(|bytes| bytes == b"\r\n\r\n") {
                if received.len() >= split + 4 + body.len() {
                    break (
                        String::from_utf8(received[..split].to_vec())
                            .unwrap()
                            .to_lowercase(),
                        received[split + 4..].to_vec(),
                    );
                }
            }
        };
        assert_eq!(actual_body, body);
        assert!(headers.contains(&format!("x-tokrate-key: {}", expected_key.to_lowercase())));
        assert!(headers.contains(&format!(
            "x-tokrate-signature: {}",
            expected_signature.to_lowercase()
        )));
        assert!(!String::from_utf8_lossy(&actual_body).contains("local-private-id"));
        connection.write_all(b"HTTP/1.1 307 Temporary Redirect\r\nLocation: http://127.0.0.1:1/forbidden\r\nContent-Length: 0\r\nConnection: close\r\n\r\n").unwrap();
    });
    let transport = reqwest::Client::builder()
        .no_proxy()
        .redirect(reqwest::redirect::Policy::none())
        .timeout(std::time::Duration::from_secs(5))
        .build()
        .unwrap();
    let result =
        crate::runtime::transmit(&transport, &format!("http://{address}/samples"), signed).await;
    server.join().unwrap();
    assert_eq!(result, Some(307));
    // The production builder refuses cleartext before making any request.
    assert!(crate::runtime::client()
        .unwrap()
        .post("http://127.0.0.1:1/samples")
        .send()
        .await
        .is_err());
}
