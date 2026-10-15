#!/usr/bin/env python3
"""Isolated CLI lifecycle smoke; synthetic logs, local mode only, no community requests."""
import datetime as dt
import json
import os
from pathlib import Path
import signal
import pty
import select
import termios
import subprocess
import sys
import tempfile
import time


def main():
    binary = str(Path(sys.argv[1]).resolve())
    with tempfile.TemporaryDirectory(prefix="tokrate-headless-smoke-") as temp:
        root = Path(temp)
        home = root / "home"
        home.mkdir()
        config, data = root / "config", root / "state"
        env = {**os.environ, "HOME": str(home), "CODEX_HOME": str(home / ".codex"),
               "CLAUDE_CONFIG_DIR": str(home / ".claude"), "GROK_HOME": str(home / ".grok"),
               "KIMI_CODE_HOME": str(home / ".kimi-code"), "XDG_CONFIG_HOME": str(home / ".config"),
               "XDG_DATA_HOME": str(home / ".local/share"), "CREDENTIALS_DIRECTORY": str(root / "must-not-be-read")}
        command = [binary, "--config-dir", str(config), "--data-dir", str(data)]

        def run(*args, check=True):
            return subprocess.run(command + list(args), env=env, text=True, capture_output=True,
                                  timeout=15, check=check)

        assert run("setup", check=False).returncode != 0, "No unattended implicit consent"
        run("setup", "--local-only")
        assert not (config / "consent-v6.json").exists()
        assert run("sharing-enabled", check=False).returncode != 0
        assert run("run", "--share", check=False).returncode != 0
        run("setup", "--share")
        assert run("sharing-enabled").returncode == 0
        # Local run must not touch credentials even when consent was accepted.
        process = subprocess.Popen(command + ["run"], env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        try:
            deadline = time.monotonic() + 10
            while not (data / "status.json").exists():
                assert process.poll() is None
                assert time.monotonic() < deadline
                time.sleep(.1)
            assert run("setup", "--local-only", check=False).returncode != 0, "Setup must refuse a running daemon"
            assert run("scan", check=False).returncode != 0, "Only one state writer"
            status = json.loads(run("status").stdout)
            assert status["running"] and status["monitoring"] and not status["sharing_active"]

            # A viewer is read-only: Q, Escape and SIGTERM restore the terminal and leave
            # the separate collector running. Use a PTY so raw-mode handling is real.
            for exit_key in (b"q", b"\x1b", None):
                master, slave = pty.openpty()
                original = termios.tcgetattr(slave)
                viewer = subprocess.Popen(command + ["status-monitor", "--demo"], env=env,
                                          stdin=slave, stdout=slave, stderr=slave)
                try:
                    output = b""
                    deadline = time.monotonic() + 10
                    while b"[ESC]" not in output:
                        assert time.monotonic() < deadline
                        if select.select([master], [], [], .2)[0]:
                            output += os.read(master, 65536)
                    if exit_key is None:
                        viewer.send_signal(signal.SIGTERM)
                    else:
                        os.write(master, exit_key)
                    assert viewer.wait(timeout=5) == 0
                    restored = termios.tcgetattr(slave)
                    # Darwin marks canonical input pending after restoring cooked mode;
                    # PENDIN is a kernel bookkeeping bit, not a raw-mode setting.
                    restored[3] &= ~getattr(termios, "PENDIN", 0)
                    original[3] &= ~getattr(termios, "PENDIN", 0)
                    assert restored == original, f"Viewer left terminal in raw mode ({exit_key!r}): {original!r} -> {restored!r}"
                    assert process.poll() is None, "Viewer stopped collector"
                finally:
                    if viewer.poll() is None:
                        viewer.terminate()
                        try:
                            viewer.wait(timeout=5)
                        except subprocess.TimeoutExpired:
                            viewer.kill()
                            viewer.wait(timeout=5)
                    os.close(master)
                    os.close(slave)

            # Create a source only after launch: this also tests late root discovery and watchers.
            sessions = home / ".codex/sessions"
            sessions.mkdir(parents=True)
            start = dt.datetime.now(dt.timezone.utc) - dt.timedelta(seconds=90)
            end = start + dt.timedelta(seconds=10)
            def event(kind, payload, at):
                return {"type": kind, "timestamp": at.isoformat(), "payload": payload}
            events = [
                event("session_meta", {"id": "SENTINEL-SESSION", "source": "cli", "model_provider": "openai", "cli_version": "0.159.2"}, start),
                event("event_msg", {"type": "task_started", "turn_id": "SENTINEL-TURN", "started_at": start.isoformat()}, start),
                event("turn_context", {"turn_id": "SENTINEL-TURN", "model": "gpt-test", "effort": "high"}, start),
                event("token_usage_record", {"turn_id": "SENTINEL-TURN", "turn_token_usage": {"output_tokens": 200}}, end),
                event("event_msg", {"type": "task_complete", "turn_id": "SENTINEL-TURN", "started_at": start.isoformat(), "completed_at": end.isoformat(), "last_agent_message": "SENTINEL-PRIVATE-CONTENT"}, end),
            ]
            (sessions / "rollout.jsonl").write_text("".join(json.dumps(e) + "\n" for e in events))
            deadline = time.monotonic() + 45
            while True:
                status = json.loads(run("status").stdout)
                if status.get("history_turns") == 1:
                    break
                assert time.monotonic() < deadline, "Late-created source was not collected"
                assert process.poll() is None
                time.sleep(.2)
            assert status["latest_turn"]["turn_throughput_tps"] == 20
            assert status["pending_samples"] == 0 and status["uploaded_samples"] == 0
            process.send_signal(signal.SIGTERM)
            stdout, stderr = process.communicate(timeout=10)
            assert process.returncode == 0, stderr
            assert "SENTINEL" not in stdout + stderr
            assert "SENTINEL" not in (data / "history.json").read_text()
            status = json.loads(run("status").stdout)
            assert not status["running"] and not status["monitoring"]
            run("scan")
            assert json.loads(run("status").stdout)["history_turns"] == 1
            run("setup", "--local-only")
            assert not (config / "consent-v6.json").exists()
        finally:
            if process.poll() is None:
                process.terminate()
                process.communicate(timeout=10)
    print("headless CLI lifecycle smoke passed (synthetic data, no uploads)")


if __name__ == "__main__":
    main()
