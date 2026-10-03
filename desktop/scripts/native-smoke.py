"""Native webview smoke test. Isolated synthetic logs; sharing is forcibly disabled."""
import datetime, json, os, pathlib, subprocess, sys, tempfile
with tempfile.TemporaryDirectory(prefix="tokrate-native-smoke-") as root:
    root = pathlib.Path(root)
    (root / "sessions").mkdir()
    now = datetime.datetime.now(datetime.timezone.utc).isoformat().replace("+00:00", "Z")
    events = [
        {"type":"session_meta","payload":{"id":"fixture-session","cli_version":"0.159.2","source":"cli","model_provider":"openai"}},
        {"type":"turn_context","payload":{"turn_id":"fixture-turn","model":"fixture-model","effort":"high"}},
        {"type":"token_usage_record","payload":{"turn_id":"fixture-turn","turn_token_usage":{"output_tokens":200}}},
        {"type":"event_msg","timestamp":now,"payload":{"type":"task_complete","turn_id":"fixture-turn","duration_ms":10000,"time_to_first_token_ms":1200}}
    ]
    (root/"sessions"/"fixture.jsonl").write_text("\n".join(json.dumps(e) for e in events)+"\n")
    env = dict(os.environ, TOKRATE_SMOKE_DIR=str(root))
    subprocess.run([str(pathlib.Path(sys.argv[1]).resolve()), "--smoke-test"], env=env, check=True, timeout=90)
    result=json.loads((root/"smoke-result.json").read_text())
    assert result == {"nativeWebview":True,"parsedFixture":True,"sharingOff":True}, result
    print(json.dumps(result))
