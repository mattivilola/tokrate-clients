#!/usr/bin/env python3
"""Exercise package and updater permissions under a real Debian 12 systemd PID 1."""

from __future__ import annotations

import fcntl
import json
import os
import pty
import pwd
import select
import shutil
import signal
import stat
import struct
import subprocess
import sys
import termios
import time
from pathlib import Path


UPDATE_ACCOUNT = "tokrate-update"
UPDATE_GROUP = "tokrate-update"
UPDATE_SERVICE = "tokrate-headless-update-check.service"
UPDATE_TIMER = "tokrate-headless-update-check.timer"
CACHE_DIR = Path("/var/cache/tokrate-headless-updates")
CACHE_FILE = CACHE_DIR / "status.json"
SETTING_FILE = Path("/etc/tokrate-headless/update-checks")


def fail(message: str) -> None:
    raise AssertionError(message)


def run(
    command: list[str],
    *,
    check: bool = True,
    timeout: int = 60,
    input_text: str | None = None,
) -> subprocess.CompletedProcess[str]:
    result = subprocess.run(
        command,
        check=False,
        capture_output=True,
        text=True,
        timeout=timeout,
        input=input_text,
    )
    if check and result.returncode != 0:
        fail(
            f"command failed ({result.returncode}): {' '.join(command)}\n"
            f"stdout:\n{result.stdout}\nstderr:\n{result.stderr}"
        )
    return result


def systemctl(*arguments: str, check: bool = True) -> str:
    return run(["systemctl", *arguments], check=check).stdout.strip()


def assert_inactive(unit: str) -> None:
    active = systemctl("is-active", unit, check=False)
    if active not in ("inactive", "unknown", "failed"):
        fail(f"package installation unexpectedly activated {unit}: {active}")


def assert_static_account() -> None:
    account = pwd.getpwnam(UPDATE_ACCOUNT)
    if not 1 <= account.pw_uid <= 999:
        fail(f"updater UID is not a system UID: {account.pw_uid}")
    if account.pw_gid <= 0 or account.pw_gid > 999:
        fail(f"updater GID is not a system GID: {account.pw_gid}")
    if account.pw_dir != "/nonexistent" or account.pw_shell != "/usr/sbin/nologin":
        fail("updater account must have no home and a non-login shell")
    group = run(["getent", "group", UPDATE_GROUP]).stdout.strip().split(":")
    if len(group) != 4 or int(group[2]) != account.pw_gid or group[3]:
        fail("updater account must use its dedicated empty primary group")
    groups = run(["id", "-G", UPDATE_ACCOUNT]).stdout.strip().split()
    if groups != [str(account.pw_gid)]:
        fail(f"updater account has unexpected supplementary groups: {groups}")


def assert_service_account_isolation(user_home: Path) -> None:
    config_canary = Path("/etc/tokrate-headless/.runtime-canary")
    credential_canary = Path("/etc/credstore.encrypted/.runtime-canary")
    state_canary = Path("/var/lib/tokrate-headless/.runtime-canary")
    home_canary = user_home / ".runtime-canary"
    for path in (config_canary, credential_canary, state_canary, home_canary):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text("runtime test canary\n")
        path.chmod(0o644)
    user_home.chmod(0o755)

    dropin_dir = Path("/run/systemd/system") / f"{UPDATE_SERVICE}.d"
    dropin_dir.mkdir(parents=True, exist_ok=True)
    lines = ["[Service]"]
    for path in (home_canary, config_canary, credential_canary, state_canary):
        lines.append(f"ExecStartPre=/usr/bin/test ! -r {path}")
    lines.extend(
        [
            "Environment=HTTP_PROXY=http://127.0.0.1:1",
            "Environment=HTTPS_PROXY=http://127.0.0.1:1",
            "Environment=http_proxy=http://127.0.0.1:1",
            "Environment=https_proxy=http://127.0.0.1:1",
            "Environment=NO_PROXY=",
            "Environment=no_proxy=",
        ]
    )
    (dropin_dir / "runtime-test.conf").write_text("\n".join(lines) + "\n")
    run(["systemctl", "daemon-reload"])


def run_dashboard_as_unrelated_user(user: str, config: Path, data: Path) -> bytes:
    master, slave = pty.openpty()
    fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 50, 180, 0, 0))
    process = subprocess.Popen(
        [
            "runuser",
            "-u",
            user,
            "--",
            "/usr/bin/tokrate-headless",
            "--config-dir",
            str(config),
            "--data-dir",
            str(data),
            "status-monitor",
        ],
        stdin=slave,
        stdout=slave,
        stderr=slave,
        close_fds=True,
        env={"PATH": "/usr/sbin:/usr/bin:/sbin:/bin", "TERM": "xterm"},
    )
    os.close(slave)
    output = bytearray()
    deadline = time.monotonic() + 12
    try:
        while time.monotonic() < deadline:
            ready, _, _ = select.select([master], [], [], 0.25)
            if ready:
                try:
                    output.extend(os.read(master, 65536))
                except OSError:
                    break
            if b"Could not check for updates" in output:
                os.write(master, b"q")
                break
        if b"Could not check for updates" not in output:
            fail(f"status-monitor did not display the cached update result:\n{output.decode(errors='replace')}")
        process.wait(timeout=5)
        return bytes(output)
    finally:
        os.close(master)
        if process.poll() is None:
            process.send_signal(signal.SIGTERM)
            process.wait(timeout=5)


def assert_incompatible_account_rejected() -> None:
    run(["userdel", "--remove", UPDATE_ACCOUNT], check=False)
    run(["groupdel", UPDATE_GROUP], check=False)
    extra_group = "tokrate-test-privileged"
    run(["groupadd", "--system", extra_group])
    run(["groupadd", "--system", UPDATE_GROUP])
    run(
        [
            "useradd",
            "--system",
            "--no-create-home",
            "--home-dir",
            "/nonexistent",
            "--shell",
            "/usr/sbin/nologin",
            "--gid",
            UPDATE_GROUP,
            "--groups",
            extra_group,
            UPDATE_ACCOUNT,
        ]
    )
    incompatible = run(
        ["/usr/libexec/tokrate-headless/provision-update-user"], check=False
    )
    if incompatible.returncode == 0 or "supplementary group membership" not in incompatible.stderr:
        fail("account provisioning silently reused an updater account in an extra group")
    run(["userdel", UPDATE_ACCOUNT])
    run(["groupdel", extra_group], check=False)
    run(["groupdel", UPDATE_GROUP], check=False)
    run(["/usr/libexec/tokrate-headless/provision-update-user"])
    assert_static_account()


def main() -> None:
    if os.geteuid() != 0:
        fail("runtime test must run as root inside the disposable Debian container")
    if len(sys.argv) != 3:
        fail("usage: test-systemd-runtime.py PACKAGE.deb SOURCE_HEADLESS_DIR")
    package = Path(sys.argv[1])
    source = Path(sys.argv[2])
    if not package.is_file() or not source.is_dir():
        fail("runtime test package or source directory is missing")

    run(["dpkg", "-i", str(package)])
    assert_static_account()
    for unit in (UPDATE_SERVICE, UPDATE_TIMER):
        assert_inactive(unit)
    if systemctl("is-enabled", UPDATE_TIMER, check=False) == "enabled":
        fail("installing the Debian package must not enable the update timer")
    if SETTING_FILE.exists():
        fail("installing the Debian package must not create the machine-wide update setting")

    unit_files = {
        f"tokrate-headless-local@.service": source / "tokrate-headless-local@.service",
        f"tokrate-headless-share@.service": source / "tokrate-headless-share@.service",
    }
    for unit, source_file in unit_files.items():
        if not source_file.is_file():
            fail(f"collector unit source is missing: {unit}")
    if "RestrictAddressFamilies=AF_UNIX\n" not in unit_files["tokrate-headless-local@.service"].read_text():
        fail("local collector must remain restricted to AF_UNIX")

    user = "tokrate-runtime"
    unrelated = "tokrate-reader"
    for name in (user, unrelated):
        if run(["getent", "passwd", name], check=False).returncode == 0:
            fail(f"test account already exists: {name}")
        run(["useradd", "--create-home", "--shell", "/bin/bash", name])

    try:
        home = Path(pwd.getpwnam(user).pw_dir)
        home.chmod(0o755)
        install_result = run(
            ["bash", str(source / "install.sh"), "--user", user, "--local-only"],
            timeout=90,
        )
        unit = f"tokrate-headless-local@{user}.service"
        if f"Service restarted and running: {unit}" not in install_result.stdout:
            fail(f"standalone installer did not confirm the fresh running service:\n{install_result.stdout}")
        if "Community sharing configured: off" not in install_result.stdout:
            fail("standalone local-only install did not report sharing OFF")
        if "Automatic update checks configured: on" not in install_result.stdout:
            fail("a fresh standalone install must enable availability checks independently")
        status_output = run(
            [
                "runuser",
                "-u",
                user,
                "--",
                "/usr/bin/tokrate-headless",
                "--config-dir",
                f"/etc/tokrate-headless/{user}",
                "--data-dir",
                f"/var/lib/tokrate-headless/{user}",
                "status",
            ]
        )
        collector_status = json.loads(status_output.stdout)
        if collector_status.get("sharing_consent") is not False or collector_status.get("sharing_active") is not False:
            fail("local-only collector status must remain disconnected from sharing")
        if collector_status.get("running") is not True:
            fail("local collector did not publish a live status heartbeat")
        if systemctl("is-active", UPDATE_TIMER) != "active":
            fail("fresh standalone install did not enable the separate update-check timer")

        run(["/usr/bin/tokrate-headless", "update-checks", "off"])
        if SETTING_FILE.read_text() != "off\n":
            fail("automatic check opt-out was not persisted")
        if systemctl("is-active", UPDATE_TIMER, check=False) not in ("inactive", "unknown"):
            fail("turning automatic checks off did not stop the daily timer")

        assert_service_account_isolation(home)
        first_check = run(["systemctl", "start", UPDATE_SERVICE], timeout=30)
        del first_check
        if systemctl("show", "--property=Result", "--value", UPDATE_SERVICE) != "success":
            fail("manual update check failed before publishing its readable cache")
        assert_inactive(UPDATE_SERVICE)

        cache_meta = CACHE_FILE.stat()
        if stat.S_IMODE(cache_meta.st_mode) != 0o644:
            fail(f"update status cache must be mode 0644, got {oct(stat.S_IMODE(cache_meta.st_mode))}")
        if pwd.getpwuid(cache_meta.st_uid).pw_name != UPDATE_ACCOUNT:
            fail("update cache must be owned by the static checker account")
        if stat.S_IMODE(CACHE_DIR.stat().st_mode) != 0o755:
            fail("update cache directory must be readable but not writable by local users")

        reader_home = Path(pwd.getpwnam(unrelated).pw_dir)
        reader_cache = run(["runuser", "-u", unrelated, "--", "/bin/cat", str(CACHE_FILE)])
        first_record = json.loads(reader_cache.stdout)
        if first_record.get("result") != "error":
            fail("forced network failure did not publish an error status")
        if run(["runuser", "-u", unrelated, "--", "test", "-r", str(CACHE_FILE)]).returncode != 0:
            fail("an unrelated local user could not read the update cache")
        if run(["runuser", "-u", unrelated, "--", "test", "-w", str(CACHE_DIR)], check=False).returncode == 0:
            fail("an unrelated local user can write the update cache directory")
        if run(["runuser", "-u", unrelated, "--", "/bin/sh", "-c", f"printf tamper >> {CACHE_FILE}"], check=False).returncode == 0:
            fail("an unrelated local user can modify the update status cache")

        installed_version = run(["/usr/bin/tokrate-headless", "--version"]).stdout.strip().split()[-1]
        seed = {
            "schemaVersion": 1,
            "checkedAt": "2026-10-16T00:00:00Z",
            "installedVersion": installed_version,
            "result": "error",
            "availableVersion": None,
            "releaseSequence": 987654321,
            "releaseVersion": installed_version,
            "releasedAt": None,
            "expiresAt": None,
            "message": "synthetic cache high-water fixture",
        }
        CACHE_FILE.write_text(json.dumps(seed) + "\n")
        CACHE_FILE.chmod(0o644)
        shutil.chown(CACHE_FILE, user=UPDATE_ACCOUNT, group=UPDATE_GROUP)
        run(["systemctl", "start", UPDATE_SERVICE], timeout=30)
        after_failure = json.loads(run(["/bin/cat", str(CACHE_FILE)]).stdout)
        if after_failure.get("releaseSequence") != 987654321:
            fail("a failed feed request must retain the last release sequence")
        if after_failure.get("result") != "error":
            fail("failed feed request must be reported as an error")
        if SETTING_FILE.read_text() != "off\n":
            fail("a manual check must work without changing the automatic-check OFF setting")

        reader_config = reader_home / ".config/tokrate-runtime"
        reader_data = reader_home / ".local/state/tokrate-runtime"
        reader_config.mkdir(parents=True, exist_ok=True)
        reader_data.mkdir(parents=True, exist_ok=True)
        shutil.chown(reader_config, user=unrelated, group=unrelated)
        shutil.chown(reader_data, user=unrelated, group=unrelated)
        status = run(
            [
                "runuser",
                "-u",
                unrelated,
                "--",
                "/usr/bin/tokrate-headless",
                "--config-dir",
                str(reader_config),
                "--data-dir",
                str(reader_data),
                "status",
            ]
        )
        update_status = json.loads(status.stdout).get("update_check", {})
        if update_status.get("state") != "error" or update_status.get("automaticChecks") != "off":
            fail(f"status JSON did not expose the cached manual-check result: {update_status}")
        rendered = run_dashboard_as_unrelated_user(unrelated, reader_config, reader_data)
        if b"Could not check for updates" not in rendered:
            fail("status-monitor did not render the update-check cache")

        assert_incompatible_account_rejected()
        print("Debian 12 systemd runtime checks passed")
    finally:
        run(["systemctl", "stop", UPDATE_SERVICE, UPDATE_TIMER, f"tokrate-headless-local@{user}.service"], check=False)
        run(["systemctl", "disable", UPDATE_TIMER, f"tokrate-headless-local@{user}.service"], check=False)
        shutil.rmtree(Path("/run/systemd/system") / f"{UPDATE_SERVICE}.d", ignore_errors=True)
        run(["systemctl", "daemon-reload"], check=False)
        for name in (user, unrelated):
            run(["userdel", "--remove", name], check=False)


if __name__ == "__main__":
    main()
