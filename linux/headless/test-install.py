#!/usr/bin/env python3
"""Static integration checks for the headless Debian installer and units."""

from pathlib import Path
import json
import os
import pwd
import shutil
import stat
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parent
INSTALLER = ROOT / "install.sh"
PACKAGER = ROOT / "package.sh"
BOOTSTRAP = ROOT / "bootstrap.sh"
LOCAL_UNIT = ROOT / "tokrate-headless-local@.service"
SHARE_UNIT = ROOT / "tokrate-headless-share@.service"
UPDATE_CHECK_SERVICE = ROOT / "tokrate-headless-update-check.service"
UPDATE_CHECK_TIMER = ROOT / "tokrate-headless-update-check.timer"
UPDATE_SYSUSERS = ROOT / "tokrate-update.sysusers"
UPDATE_USER_HELPER = ROOT / "provision-update-user.sh"


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def section(text: str, name: str) -> str:
    marker = f"[{name}]"
    require(marker in text, f"missing systemd section {marker}")
    return text.split(marker, 1)[1].split("[", 1)[0]


def main() -> None:
    for path in (INSTALLER, PACKAGER, BOOTSTRAP, UPDATE_USER_HELPER):
        result = subprocess.run(["bash", "-n", str(path)], check=False)
        require(result.returncode == 0, f"shell syntax check failed: {path.name}")

    help_result = subprocess.run(
        ["bash", str(INSTALLER), "--help"], check=False, capture_output=True, text=True
    )
    require(help_result.returncode == 0, "installer --help should not require root")
    require("--user USER" in help_result.stdout, "installer must require an explicit target user")

    installer = INSTALLER.read_text()
    stop_local = installer.index('stop_if_running "$local_unit"')
    stop_share = installer.index('stop_if_running "$share_unit"')
    setup = installer.index('"${setup_command[@]}"')
    key = installer.index('provision-key --output "$credential_file"')
    require(stop_local < setup and stop_share < setup, "both units must stop before setup")
    require(stop_local < key and stop_share < key, "both units must stop before key provisioning")
    require('TARGET_USER="${SUDO_USER' not in installer, "target user must never be guessed from sudo")
    require("((target_uid != 0))" in installer, "installer must refuse the root target account")
    require('"$caller_user" == "$TARGET_USER"' in installer, "source environment must only pass for the same caller account")
    require("assert_root_owned \"$path\"" in installer and "refusing existing path not owned by root" in installer, "installer must refuse pre-existing non-root-owned system paths")
    require('"$(dirname -- "$binary_target")"' in installer, "installer must create the binary destination in a staged integration root")
    require('rm -f -- "$config_dir/consent-v6.json"' in installer, "local-only switch must remove only current consent marker")
    require('sharing-enabled' in installer and 'MODE=share' in installer and 'MODE=local' in installer, "interactive setup choice must select exactly one service mode")
    require('systemctl enable --now "$share_unit"' in installer, "selected share unit must be enabled and started")
    require('systemctl enable --now "$local_unit"' in installer, "selected local unit must be enabled and started")
    require('systemctl enable --now "$UPDATE_CHECK_TIMER"' in installer, "update checks must be enabled independently of sharing")
    require('systemctl disable --now "$UPDATE_CHECK_TIMER"' in installer, "saved update-check opt-out must be honored")
    require("mapfile -t update_setting_lines" in installer, "installer must reject ambiguous update-check settings")
    require('systemctl show --property=MainPID --value "$selected_unit"' in installer, "installer must verify the selected service process")
    require('"running": true' in installer and '"monitoring": true' in installer, "installer must require a live daemon heartbeat before claiming success")
    require('Updated %s → %s' in installer and 'Already up to date: %s' in installer, "installer must state whether the binary changed")

    update_check_service = UPDATE_CHECK_SERVICE.read_text()
    update_check_timer = UPDATE_CHECK_TIMER.read_text()
    update_check_service_section = section(update_check_service, "Service")
    require("User=tokrate-update" in update_check_service_section and "Group=tokrate-update" in update_check_service_section, "update checks must use the dedicated unprivileged system account")
    require("DynamicUser=" not in update_check_service_section, "update cache must remain readable after the oneshot user exits")
    require("CacheDirectory=tokrate-headless-updates" in update_check_service_section, "update service must use its public cache")
    require("CacheDirectoryMode=0755" in update_check_service_section and "UMask=0022" in update_check_service_section, "update cache must be readable by local users but not writable")
    require("RemoveIPC=yes" in update_check_service_section, "update checker must clean up its IPC resources")
    require("/etc/tokrate-headless" in update_check_service_section and "/etc/credstore.encrypted" in update_check_service_section, "update service must not access config or credentials")
    require("OnCalendar=daily" in update_check_timer and "RandomizedDelaySec=" in update_check_timer, "update availability checks must run on a randomized daily timer")
    sysusers = UPDATE_SYSUSERS.read_text()
    require('u tokrate-update - "Tokrate update checker" /nonexistent /usr/sbin/nologin' in sysusers, "checker account must be a system non-login account with no home")
    helper = UPDATE_USER_HELPER.read_text()
    require('systemd-sysusers "$CONFIG"' in helper and "validate_local_account" in helper, "account provisioning must use sysusers and reject incompatible existing accounts")

    local = LOCAL_UNIT.read_text()
    local_service = section(local, "Service")
    require("ConditionPathExists=!/etc/tokrate-headless/%i/consent-v6.json" in local, "local mode must require absent consent")
    require(" run\n" in local_service and "run --share" not in local_service, "local mode must not pass --share")
    require("LoadCredentialEncrypted" not in local, "local mode must not load signing credentials")
    require("RestrictAddressFamilies=AF_UNIX\n" in local_service, "local service must have no IP network access")

    share = SHARE_UNIT.read_text()
    share_service = section(share, "Service")
    require("ConditionPathExists=/etc/tokrate-headless/%i/consent-v6.json" in share, "share mode must require current consent")
    require("run --share" in share_service, "share mode must pass --share")
    require("LoadCredentialEncrypted=signing-key:/etc/credstore.encrypted/tokrate-headless-%i.key" in share_service, "share mode must load the encrypted system credential")
    require("RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6" in share_service, "share mode must allow network access")

    packager = PACKAGER.read_text()
    postinst = packager.split("cat >\"$stage/DEBIAN/postinst\" <<'EOF'", 1)[1].split("EOF", 1)[0]
    require("daemon-reload" in postinst, "package installation must reload systemd unit definitions")
    require("systemctl enable" not in postinst and "systemctl start" not in postinst, "package postinst must not enable or start services")
    require("provision-update-user" in postinst, "Debian postinst must provision the static checker account")
    require("provision-key" not in packager and "consent-v6.json" not in packager, "package build must not create consent or credentials")
    require('"$script_dir/tokrate-headless-update-check.service"' in packager and '"$script_dir/tokrate-headless-update-check.timer"' in packager, "Debian package must contain both updater units")
    require('"$script_dir/tokrate-update.sysusers"' in packager and '"$script_dir/provision-update-user.sh"' in packager, "Debian package must contain the shared sysusers definition and validator")
    require("Depends: libc6 (>= 2.36), libgcc-s1, systemd (>= 252)" in packager, "Debian package must declare its runtime ABI and systemd requirements")

    bootstrap = BOOTSTRAP.read_text()
    verify_hash = bootstrap.index("sha256sum --check --status")
    extract_archive = bootstrap.index("tar --extract")
    run_installer = bootstrap.index('install_command=("$installer"')
    require("tokrate-headless_${TOKRATE_VERSION}_amd64.tar.gz" in bootstrap and "tokrate-headless_${TOKRATE_VERSION}_arm64.tar.gz" in bootstrap, "bootstrap must select the pinned Debian amd64 and arm64 assets")
    require(verify_hash < extract_archive < run_installer, "bootstrap must check the pinned archive hash before extraction and execution")
    require("readonly SHA256_AMD64=" in bootstrap and "readonly SHA256_ARM64=" in bootstrap, "bootstrap must hardcode a checksum for each supported architecture")
    require("root must pass --user USER explicitly" in bootstrap, "bootstrap must never guess a root target account")
    require("/dev/tty" in bootstrap, "interactive curl-pipe installs must connect setup to the controlling terminal")

    if os.environ.get("TOKRATE_HEADLESS_RUN_INSTALL_TEST") == "1":
        run_dynamic_install_test()

    print("headless Debian installer checks passed")


def run_dynamic_install_test() -> None:
    """Run the real installer against a root-owned staging tree and fake systemctl."""
    binary_text = os.environ.get("TOKRATE_HEADLESS_BINARY", "")
    binary = Path(binary_text)
    require(os.geteuid() == 0, "dynamic installer checks must run as root inside the disposable Debian container")
    require(binary_text and binary.is_file() and os.access(binary, os.X_OK), "TOKRATE_HEADLESS_BINARY must name the built Linux executable")
    require(shutil.which("runuser") is not None, "runuser is required for dynamic installer checks")
    require(shutil.which("useradd") is not None and shutil.which("userdel") is not None, "useradd and userdel are required for dynamic installer checks")
    require(shutil.which("systemd-creds") is not None, "systemd-creds is required for credential roundtrip checks")

    credential_secret = Path("/var/lib/systemd/credential.secret")
    if not credential_secret.exists():
        subprocess.run(["systemd-creds", "setup"], check=True, capture_output=True)

    with tempfile.TemporaryDirectory(prefix="tokrate-headless-install-test-", dir="/tmp") as temp_name:
        temp = Path(temp_name)
        temp.chmod(0o711)
        root = temp / "root"
        root.mkdir(mode=0o755)
        root.chmod(0o755)
        fakebin = temp / "fakebin"
        fakebin.mkdir(mode=0o755)
        stopped = temp / "stopped"
        stopped.mkdir(mode=0o755)
        log = temp / "systemctl.log"
        fake_systemctl = fakebin / "systemctl"
        fake_systemctl.write_text(
            "#!/bin/sh\n"
            "set -eu\n"
            "printf '%s\\n' \"$*\" >>\"$TOKRATE_FAKE_SYSTEMCTL_LOG\"\n"
            "case \"$1\" in\n"
            "  show)\n"
            "    case \"$2\" in\n"
            "      --property=Version) printf '252\\n' ;;\n"
            "      --property=LoadState) printf 'loaded\\n' ;;\n"
            "      --property=ActiveState)\n"
            "        unit=${4:-manager}\n"
            "        if [ -e \"$TOKRATE_FAKE_SYSTEMCTL_STOPPED/$unit\" ]; then printf 'inactive\\n'; else printf 'active\\n'; fi\n"
            "        ;;\n"
            "      *) exit 2 ;;\n"
            "    esac\n"
            "    ;;\n"
            "  stop) touch \"$TOKRATE_FAKE_SYSTEMCTL_STOPPED/$2\" ;;\n"
            "  enable) rm -f \"$TOKRATE_FAKE_SYSTEMCTL_STOPPED/${3:-$2}\" ;;\n"
            "  *) ;;\n"
            "esac\n"
        )
        fake_systemctl.chmod(0o755)

        username = f"tkheadless{os.getpid()}"
        home = temp / "home"
        subprocess.run(
            ["useradd", "--system", "--user-group", "--create-home", "--home-dir", str(home), "--shell", "/usr/sbin/nologin", username],
            check=True,
            capture_output=True,
        )
        try:
            account = pwd.getpwnam(username)
            source_home = temp / "custom codex home"
            env = os.environ.copy()
            env.update(
                {
                    "PATH": str(fakebin) + os.pathsep + env.get("PATH", ""),
                    "TOKRATE_HEADLESS_TESTING": "1",
                    "TOKRATE_HEADLESS_TEST_ROOT": str(root),
                    "TOKRATE_FAKE_SYSTEMCTL_LOG": str(log),
                    "TOKRATE_FAKE_SYSTEMCTL_STOPPED": str(stopped),
                    "SUDO_USER": username,
                    "CODEX_HOME": str(source_home),
                }
            )
            config = root / "etc/tokrate-headless" / username
            encrypted_key = root / "etc/credstore.encrypted" / f"tokrate-headless-{username}.key"
            identity_marker = config / "identity-provisioned"
            consent_marker = config / "consent-v6.json"

            def install(*mode: str, stdin: int | None = subprocess.DEVNULL) -> subprocess.CompletedProcess[str]:
                for item in stopped.iterdir():
                    item.unlink()
                log.write_text("")
                return subprocess.run(
                    ["bash", str(INSTALLER), "--user", username, "--binary", str(binary), *mode],
                    env=env,
                    stdin=stdin,
                    capture_output=True,
                    text=True,
                    check=False,
                )

            result = install("--share")
            require(result.returncode == 0, f"first share install failed: {result.stderr}")
            update_setting = root / "etc/tokrate-headless/update-checks"
            require(update_setting.read_text() == "on\n", "first explicit install must enable update checks independently")
            require("Automatic update checks configured: on" in result.stdout, "installer must report the update-check setting separately")
            require("Service restarted and running:" in result.stdout, "installer must report the selected service health result")
            require("Installed binary version:" in result.stdout, "first install must identify the installed binary version")
            require(config.is_dir() and config.stat().st_uid == 0 and stat.S_IMODE(config.stat().st_mode) == 0o755, "config directory must be root-owned and non-writable by the target account")
            require(json.loads((config / "settings.json").read_text())["codex"] == str(source_home / "sessions"), "same-account CODEX_HOME must be captured during setup")
            require(consent_marker.is_file(), "share install must promote the current consent marker")
            require(identity_marker.is_file(), "share install must persist the identity-provisioned marker")
            require(encrypted_key.is_file() and encrypted_key.stat().st_uid == 0, "share install must create a root-owned encrypted key")
            encrypted_before = encrypted_key.read_bytes()
            decrypted = subprocess.run(
                ["systemd-creds", "decrypt", "--name=signing-key", "--with-key=host", str(encrypted_key), "-"],
                check=True,
                capture_output=True,
            )
            require(len(decrypted.stdout) == 32, "host-encrypted systemd credential must decrypt to exactly 32 bytes")
            calls = log.read_text().splitlines()
            require(sum(line.startswith("stop ") for line in calls) >= 2, "installer must stop both modes before changing config")
            require(any(line.startswith(f"enable --now tokrate-headless-share@{username}.service") for line in calls), "share install must enable only the selected share service")

            # A rerun without a mode must reuse setup-complete and consent, so
            # it succeeds with stdin closed instead of prompting again.
            result = install()
            require(result.returncode == 0, f"no-mode reinstall should reuse saved choice: {result.stderr}")
            require("Already up to date:" in result.stdout, "same-version reinstall must report the installed version is current")
            require(encrypted_key.read_bytes() == encrypted_before, "reinstall must reuse, not replace, the encrypted identity")

            update_setting.write_text("off\n")
            result = install()
            require(result.returncode == 0, f"installer rerun with update checks off failed: {result.stderr}")
            require(update_setting.read_text() == "off\n", "installer rerun must preserve update-check opt-out")
            calls = log.read_text().splitlines()
            require(any(line.startswith("disable --now tokrate-headless-update-check.timer") for line in calls), "saved opt-out must keep the timer disabled")

            result = install("--local-only")
            require(result.returncode == 0, f"local-only mode switch failed: {result.stderr}")
            require(not consent_marker.exists(), "local-only mode must remove the authoritative consent marker")
            require(identity_marker.is_file() and encrypted_key.read_bytes() == encrypted_before, "turning sharing off must preserve the provisioned identity")
            calls = log.read_text().splitlines()
            require(any(line.startswith(f"enable --now tokrate-headless-local@{username}.service") for line in calls), "local-only install must enable the selected local service")
            require(update_setting.read_text() == "off\n", "local-only mode must preserve the independent update-check setting")

            encrypted_key.unlink()
            result = install("--share")
            require(result.returncode != 0 and "encrypted key is missing" in result.stderr, "missing previously provisioned identity must fail closed")
            require(not encrypted_key.exists(), "failed re-provisioning must not silently create a replacement key")

            encrypted_key.write_bytes(encrypted_before)
            encrypted_key.chmod(0o600)
            result = install("--share")
            require(result.returncode == 0, f"restored encrypted identity should be reused: {result.stderr}")
            require(encrypted_key.read_bytes() == encrypted_before, "restored identity ciphertext must be preserved byte-for-byte")
        finally:
            subprocess.run(["userdel", "--remove", username], check=False, capture_output=True)


if __name__ == "__main__":
    main()
