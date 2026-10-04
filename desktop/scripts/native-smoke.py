"""Native webview smoke test using isolated synthetic logs; sharing is disabled."""

import datetime
import json
import os
import pathlib
import subprocess
import sys
import tempfile


def write_jsonl(path: pathlib.Path, records: list[dict]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("\n".join(json.dumps(record) for record in records) + "\n")


with tempfile.TemporaryDirectory(prefix="tokrate-native-smoke-") as temporary:
    root = pathlib.Path(temporary)
    codex_root = root / "sessions"
    claude_root = root / "claude-projects"
    grok_root = root / "grok-sessions"
    now = datetime.datetime.now(datetime.timezone.utc)
    completed_at = now.isoformat().replace("+00:00", "Z")
    started_at = (now - datetime.timedelta(seconds=10)).isoformat().replace(
        "+00:00", "Z"
    )
    persisted_at = (now + datetime.timedelta(seconds=1)).isoformat().replace(
        "+00:00", "Z"
    )

    write_jsonl(
        codex_root / "fixture.jsonl",
        [
            {
                "type": "session_meta",
                "payload": {
                    "id": "fixture-session",
                    "cli_version": "0.159.2",
                    "source": "cli",
                    "model_provider": "openai",
                },
            },
            {
                "type": "turn_context",
                "payload": {
                    "turn_id": "fixture-turn",
                    "model": "fixture-model",
                    "effort": "high",
                },
            },
            {
                "type": "token_usage_record",
                "payload": {
                    "turn_id": "fixture-turn",
                    "turn_token_usage": {"output_tokens": 200},
                },
            },
            {
                "type": "event_msg",
                "timestamp": completed_at,
                "payload": {
                    "type": "task_complete",
                    "turn_id": "fixture-turn",
                    "duration_ms": 10000,
                    "time_to_first_token_ms": 1200,
                },
            },
        ],
    )

    write_jsonl(
        claude_root / "fixture-project" / "transcript.jsonl",
        [
            {
                "type": "user",
                "timestamp": started_at,
                "isSidechain": False,
                "userType": "external",
                "uuid": "claude-fixture-user",
                "version": "1.2.3",
                "message": {
                    "id": "claude-fixture-user",
                    "role": "user",
                    "content": "Synthetic smoke prompt.",
                },
            },
            {
                "type": "assistant",
                "timestamp": completed_at,
                "isSidechain": False,
                "userType": "external",
                "version": "1.2.3",
                "message": {
                    "id": "claude-fixture-message",
                    "role": "assistant",
                    "model": "claude-fixture-model",
                    "stop_reason": "end_turn",
                    "content": [{"type": "text", "text": "Synthetic response."}],
                    "usage": {"output_tokens": 300},
                    "effort": "high",
                },
            },
        ],
    )

    session_id = "grok-fixture-session"
    session_dir = grok_root / session_id
    write_jsonl(
        session_dir / "events.jsonl",
        [
            {
                "type": "turn_started",
                "schema_version": "1.0",
                "ts": started_at,
                "session_id": session_id,
                "turn_number": 1,
                "model_id": "grok-fixture-model",
                "session_relationship": "primary",
            },
            {
                "type": "turn_ended",
                "schema_version": "1.0",
                "ts": completed_at,
                "session_id": session_id,
                "outcome": "completed",
            },
        ],
    )
    (session_dir / "usage.json").write_text(
        json.dumps(
            {
                "sessionId": session_id,
                "updatedAt": persisted_at,
                "session": {},
                "turns": [
                    {
                        "turnNumber": 1,
                        "endedAt": persisted_at,
                        "outputTokens": 240,
                        "reasoningTokens": 20,
                        "modelCalls": 1,
                        "usageIsIncomplete": False,
                        "primaryModelId": "grok-fixture-model",
                        "modelUsage": {"grok-fixture-model": {"outputTokens": 240}},
                    }
                ],
            }
        )
    )

    env = dict(os.environ, TOKRATE_SMOKE_DIR=str(root))
    try:
        subprocess.run(
            [str(pathlib.Path(sys.argv[1]).resolve()), "--smoke-test"],
            env=env,
            check=True,
            timeout=90,
        )
    except (subprocess.TimeoutExpired, subprocess.CalledProcessError):
        diagnostic = root / "smoke-state.json"
        print(
            "Native smoke diagnostics:",
            diagnostic.read_text() if diagnostic.exists() else "monitor never started",
            flush=True,
        )
        raise
    result = json.loads((root / "smoke-result.json").read_text())
    assert result == {
        "nativeWebview": True,
        "parsedFixture": True,
        "sharingOff": True,
        "updatesOff": True,
    }, result
    print(json.dumps(result))
