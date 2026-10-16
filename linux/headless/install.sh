#!/usr/bin/env bash
set -Eeuo pipefail

readonly APP=tokrate-headless
readonly LOCAL_TEMPLATE=tokrate-headless-local@.service
readonly SHARE_TEMPLATE=tokrate-headless-share@.service
readonly UPDATE_CHECK_SERVICE=tokrate-headless-update-check.service
readonly UPDATE_CHECK_TIMER=tokrate-headless-update-check.timer
TEST_ROOT=${TOKRATE_HEADLESS_TEST_ROOT:-}
CONFIG_ROOT=/etc/tokrate-headless
UPDATE_SETTING=/etc/tokrate-headless/update-checks
CREDENTIAL_ROOT=/etc/credstore.encrypted
UNIT_DIR=/usr/lib/systemd/system
SYSUSERS_DIR=/usr/lib/sysusers.d
LIBEXEC_DIR=/usr/libexec/tokrate-headless
UPDATE_LOCK=/run/tokrate-headless/update.lock

usage() {
  cat <<'EOF'
Install Tokrate Headless on a Debian 12+ system.

Usage: install.sh --user USER [--binary PATH] [--share | --local-only]

Without a mode flag, first-time setup shows the sharing notice and asks once;
reruns reuse the saved sharing choice. For unattended use, pass exactly one of
--share or --local-only.
The target account must be a non-root local account.
EOF
}

fail() {
  printf 'tokrate-headless installer: %s\n' "$*" >&2
  exit 1
}

if [[ -n "$TEST_ROOT" ]]; then
  [[ "${TOKRATE_HEADLESS_TESTING:-}" == 1 ]] || fail 'staged path override is reserved for the isolated integration test'
  [[ "$TEST_ROOT" == /tmp/tokrate-headless-install-test-*/root ]] || fail 'staged install root must be the test script temporary root under /tmp'
  [[ -d "$TEST_ROOT" && ! -L "$TEST_ROOT" ]] || fail 'staged install root must be an existing real directory'
  CONFIG_ROOT="$TEST_ROOT/etc/tokrate-headless"
  UPDATE_SETTING="$CONFIG_ROOT/update-checks"
  CREDENTIAL_ROOT="$TEST_ROOT/etc/credstore.encrypted"
  UNIT_DIR="$TEST_ROOT/usr/lib/systemd/system"
  SYSUSERS_DIR="$TEST_ROOT/usr/lib/sysusers.d"
  LIBEXEC_DIR="$TEST_ROOT/usr/libexec/tokrate-headless"
  UPDATE_LOCK="$TEST_ROOT/run/tokrate-headless/update.lock"
fi

TARGET_USER=
SOURCE_BINARY=/usr/bin/tokrate-headless
MODE=

while (($#)); do
  case "$1" in
    --user)
      (($# >= 2)) || fail '--user requires a username'
      TARGET_USER=$2
      shift 2
      ;;
    --binary)
      (($# >= 2)) || fail '--binary requires a path'
      SOURCE_BINARY=$2
      shift 2
      ;;
    --share)
      [[ -z "$MODE" ]] || fail 'choose only one of --share or --local-only'
      MODE=share
      shift
      ;;
    --local-only)
      [[ -z "$MODE" ]] || fail 'choose only one of --share or --local-only'
      MODE=local
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      fail "unknown option: $1"
      ;;
  esac
done

[[ $EUID -eq 0 ]] || fail 'run this installer as root (for example with sudo)'
[[ -n "$TARGET_USER" ]] || fail '--user is required; the installer never guesses a target account'
[[ "$TARGET_USER" =~ ^[a-zA-Z_][a-zA-Z0-9_.-]*\$?$ ]] || fail 'username contains unsupported characters'

command -v getent >/dev/null || fail 'getent is required'
command -v id >/dev/null || fail 'id is required'
command -v runuser >/dev/null || fail 'runuser is required'
command -v systemctl >/dev/null || fail 'systemctl is required'
command -v install >/dev/null || fail 'install is required'
command -v mktemp >/dev/null || fail 'mktemp is required'
command -v stat >/dev/null || fail 'stat is required'
command -v date >/dev/null || fail 'date is required'
command -v flock >/dev/null || fail 'flock is required'

lock_dir=$(dirname -- "$UPDATE_LOCK")
if [[ ! -e "$lock_dir" && ! -L "$lock_dir" ]]; then
  install -d -o root -g root -m 0755 "$lock_dir"
fi
[[ -d "$lock_dir" && ! -L "$lock_dir" && "$(stat -c %u -- "$lock_dir")" == 0 ]] || fail 'update lock directory is unsafe'
lock_dir_mode=$(stat -c %a -- "$lock_dir") || fail 'could not inspect update lock directory permissions'
(( (0$lock_dir_mode & 022) == 0 )) || fail 'update lock directory must not be writable by group or others'
if [[ -e "$UPDATE_LOCK" || -L "$UPDATE_LOCK" ]]; then
  [[ -f "$UPDATE_LOCK" && ! -L "$UPDATE_LOCK" && "$(stat -c %u -- "$UPDATE_LOCK")" == 0 ]] || fail 'update lock must be a root-owned regular file'
  lock_mode=$(stat -c %a -- "$UPDATE_LOCK") || fail 'could not inspect update lock permissions'
  (( (0$lock_mode & 077) == 0 )) || fail 'update lock must be private to root'
fi
umask 077
exec {update_lock_fd}>>"$UPDATE_LOCK"
[[ -f "$UPDATE_LOCK" && ! -L "$UPDATE_LOCK" && "$(stat -c %u -- "$UPDATE_LOCK")" == 0 ]] || fail 'could not open the update lock safely'
flock -x "$update_lock_fd" || fail 'could not acquire the Tokrate update lock'

account=$(getent passwd "$TARGET_USER") || fail "account does not exist: $TARGET_USER"
IFS=: read -r account_name _ target_uid target_gid _ target_home _ <<<"$account"
[[ "$account_name" == "$TARGET_USER" && "$target_uid" =~ ^[0-9]+$ && "$target_gid" =~ ^[0-9]+$ ]] || fail 'could not resolve target account safely'
((target_uid != 0)) || fail 'refusing to install for root; choose a non-root --user'
[[ -d "$target_home" && ! -L "$target_home" ]] || fail "target home must be an existing real directory: $target_home"
[[ -x "$SOURCE_BINARY" && -f "$SOURCE_BINARY" && ! -L "$SOURCE_BINARY" ]] || fail "headless binary is missing or unsafe: $SOURCE_BINARY"

local_unit="${APP}-local@${TARGET_USER}.service"
share_unit="${APP}-share@${TARGET_USER}.service"
config_dir="${CONFIG_ROOT}/${TARGET_USER}"
credential_file="${CREDENTIAL_ROOT}/${APP}-${TARGET_USER}.key"
binary_target=/usr/bin/tokrate-headless
[[ -z "$TEST_ROOT" ]] || binary_target="$TEST_ROOT$binary_target"
state_dir="/var/lib/${APP}/${TARGET_USER}"
local_template_path="${UNIT_DIR}/${LOCAL_TEMPLATE}"
share_template_path="${UNIT_DIR}/${SHARE_TEMPLATE}"
update_check_service_path="${UNIT_DIR}/${UPDATE_CHECK_SERVICE}"
update_check_timer_path="${UNIT_DIR}/${UPDATE_CHECK_TIMER}"
sysusers_config_path="${SYSUSERS_DIR}/tokrate-update.conf"
provision_update_user_path="${LIBEXEC_DIR}/provision-update-user"
identity_marker="$config_dir/identity-provisioned"

# Availability checks have a root-managed machine-wide setting, independent of
# the target account's sharing consent. A new explicit install enables checks;
# subsequent installer runs preserve the administrator's saved choice.
update_checks=on
if [[ -e "$UPDATE_SETTING" || -L "$UPDATE_SETTING" ]]; then
  [[ -f "$UPDATE_SETTING" && ! -L "$UPDATE_SETTING" ]] || fail 'update-check setting must be a regular file'
  [[ "$(stat -c %u -- "$UPDATE_SETTING")" == 0 ]] || fail 'update-check setting must be owned by root'
  setting_mode=$(stat -c %a -- "$UPDATE_SETTING") || fail 'could not inspect update-check setting permissions'
  (( (0$setting_mode & 022) == 0 )) || fail 'update-check setting must not be writable by group or others'
  mapfile -t update_setting_lines <"$UPDATE_SETTING"
  [[ ${#update_setting_lines[@]} -eq 1 ]] || fail 'update-check setting must contain exactly one value'
  update_checks=${update_setting_lines[0]}
  [[ "$update_checks" == on || "$update_checks" == off ]] || fail 'update-check setting must contain exactly on or off'
fi
previous_binary_version=
if [[ -x "$binary_target" && -f "$binary_target" && ! -L "$binary_target" ]]; then
  previous_binary_version=$("$binary_target" --version 2>/dev/null | sed -n 's/^tokrate-headless //p' | head -n 1 || true)
fi

# Capture whether sharing was already configured before setup. If the encrypted
# key later disappears, an installer rerun must fail closed rather than minting
# a replacement identity behind the user's back.
had_consent=0
if [[ -e "$config_dir/consent-v6.json" || -L "$config_dir/consent-v6.json" ]]; then
  had_consent=1
fi
had_identity=0
if [[ -e "$identity_marker" || -L "$identity_marker" ]]; then
  had_identity=1
fi

systemctl show --property=Version --value >/dev/null 2>&1 || fail 'systemd manager is unavailable; run this on a booted Debian system'

stop_if_running() {
  local unit=$1
  local load_state active_state
  load_state=$(systemctl show --property=LoadState --value "$unit" 2>/dev/null) || fail "could not inspect service $unit"
  [[ "$load_state" != not-found && -n "$load_state" ]] || return 0
  active_state=$(systemctl show --property=ActiveState --value "$unit" 2>/dev/null) || fail "could not inspect service $unit"
  case "$active_state" in
    active|activating|reloading|deactivating)
      systemctl stop "$unit" || fail "could not stop service $unit"
      active_state=$(systemctl show --property=ActiveState --value "$unit" 2>/dev/null) || fail "could not confirm service stopped: $unit"
      [[ "$active_state" == inactive || "$active_state" == failed ]] || fail "service did not stop cleanly: $unit ($active_state)"
      ;;
  esac
}

# Stop both modes before touching setup state, the consent marker, or keys.
stop_if_running "$local_unit"
stop_if_running "$share_unit"

assert_real_directory() {
  local path=$1
  if [[ -L "$path" ]]; then
    fail "refusing symlink where a directory is required: $path"
  fi
  if [[ -e "$path" && ! -d "$path" ]]; then
    fail "refusing non-directory path: $path"
  fi
}

assert_regular_or_missing() {
  local path=$1
  if [[ -L "$path" ]]; then
    fail "refusing symlink where an application file is required: $path"
  fi
  if [[ -e "$path" && ! -f "$path" ]]; then
    fail "refusing non-file application path: $path"
  fi
}

assert_root_owned() {
  local path=$1 owner
  [[ -e "$path" || -L "$path" ]] || return 0
  owner=$(stat -c %u -- "$path") || fail "could not inspect ownership: $path"
  [[ "$owner" == 0 ]] || fail "refusing existing path not owned by root: $path"
}

if [[ -n "$TEST_ROOT" ]]; then
  system_paths=("$TEST_ROOT/usr" "$TEST_ROOT/usr/bin" "$TEST_ROOT/usr/lib" "$TEST_ROOT/usr/lib/systemd" "$UNIT_DIR" "$SYSUSERS_DIR" "$TEST_ROOT/usr/libexec" "$LIBEXEC_DIR" "$TEST_ROOT" "$CONFIG_ROOT" "$config_dir")
else
  system_paths=(/usr/bin /usr/lib /usr/lib/systemd "$UNIT_DIR" "$SYSUSERS_DIR" /usr/libexec "$LIBEXEC_DIR" "$CONFIG_ROOT" "$config_dir")
fi
for path in "${system_paths[@]}"; do
  assert_real_directory "$path"
  assert_root_owned "$path"
done
for path in "$binary_target" "$local_template_path" "$share_template_path" \
  "$update_check_service_path" "$update_check_timer_path" "$UPDATE_SETTING" \
  "$sysusers_config_path" "$provision_update_user_path" \
  "$config_dir/settings.json" "$config_dir/setup-complete" "$config_dir/consent-v6.json" "$identity_marker"; do
  assert_regular_or_missing "$path"
  assert_root_owned "$path"
done

if [[ "$MODE" == share ]]; then
  assert_real_directory "$CREDENTIAL_ROOT"
  assert_root_owned "$CREDENTIAL_ROOT"
  assert_regular_or_missing "$credential_file"
  assert_root_owned "$credential_file"
  if (( had_consent || had_identity )) && [[ ! -f "$credential_file" ]]; then
    fail "sharing is configured but its encrypted key is missing; restore $credential_file before enabling sharing"
  fi
fi

install -d -o root -g root -m 0755 "$CONFIG_ROOT" "$config_dir" "$UNIT_DIR" "$SYSUSERS_DIR" "$LIBEXEC_DIR" "$(dirname -- "$binary_target")"
if [[ "$SOURCE_BINARY" != "$binary_target" ]]; then
  install -o root -g root -m 0755 "$SOURCE_BINARY" "$binary_target"
else
  chown root:root "$binary_target"
  chmod 0755 "$binary_target"
fi
install -o root -g root -m 0644 "$(dirname -- "$0")/${LOCAL_TEMPLATE}" "$local_template_path"
install -o root -g root -m 0644 "$(dirname -- "$0")/${SHARE_TEMPLATE}" "$share_template_path"
install -o root -g root -m 0644 "$(dirname -- "$0")/${UPDATE_CHECK_SERVICE}" "$update_check_service_path"
install -o root -g root -m 0644 "$(dirname -- "$0")/${UPDATE_CHECK_TIMER}" "$update_check_timer_path"
install -o root -g root -m 0644 "$(dirname -- "$0")/tokrate-update.sysusers" "$sysusers_config_path"
install -o root -g root -m 0755 "$(dirname -- "$0")/provision-update-user.sh" "$provision_update_user_path"
if [[ -z "$TEST_ROOT" ]]; then
  "$provision_update_user_path"
fi
if [[ ! -e "$UPDATE_SETTING" ]]; then
  install -o root -g root -m 0644 /dev/null "$UPDATE_SETTING"
  printf 'on\n' >"$UPDATE_SETTING"
fi

# The setup directory is created by root, then only its private children are
# writable by the target account. The trap removes this exact mktemp path.
setup_tmp=$(mktemp -d /tmp/tokrate-headless-setup.XXXXXXXX)
stage_dir=
cleanup() {
  if [[ -n "${stage_dir:-}" && "$stage_dir" == "$config_dir"/.install.* && -d "$stage_dir" && ! -L "$stage_dir" ]]; then
    rm -rf -- "$stage_dir"
  fi
  if [[ -n "${setup_tmp:-}" && "$setup_tmp" == /tmp/tokrate-headless-setup.* && -d "$setup_tmp" && ! -L "$setup_tmp" ]]; then
    rm -rf -- "$setup_tmp"
  fi
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM
chmod 0711 "$setup_tmp"
setup_config="$setup_tmp/config"
setup_data="$setup_tmp/data"
install -d -o "$target_uid" -g "$target_gid" -m 0700 "$setup_config" "$setup_data"
for name in settings.json setup-complete consent-v6.json; do
  if [[ -f "$config_dir/$name" ]]; then
    install -o "$target_uid" -g "$target_gid" -m 0600 "$config_dir/$name" "$setup_config/$name"
  fi
done

target_env=("HOME=$target_home" "USER=$TARGET_USER" "LOGNAME=$TARGET_USER")
caller_user=${SUDO_USER:-}
if [[ -n "$caller_user" && "$caller_user" == "$TARGET_USER" ]] && caller_record=$(getent passwd "$caller_user"); then
  IFS=: read -r caller_name _ caller_uid _ _ _ _ <<<"$caller_record"
  if [[ "$caller_name" == "$TARGET_USER" && "$caller_uid" == "$target_uid" && "$target_uid" != 0 ]]; then
    for env_name in CODEX_HOME CLAUDE_CONFIG_DIR GROK_HOME KIMI_CODE_HOME XDG_CONFIG_HOME XDG_DATA_HOME; do
      env_value=${!env_name-}
      [[ -n "$env_value" ]] && target_env+=("${env_name}=${env_value}")
    done
  fi
fi

setup_command=("$binary_target" --config-dir "$setup_config" --data-dir "$setup_data" setup)
if [[ "$MODE" == share ]]; then
  setup_command+=(--share)
elif [[ "$MODE" == local ]]; then
  setup_command+=(--local-only)
fi
if [[ -n "$MODE" ]]; then
  runuser -u "$TARGET_USER" -- env -i "${target_env[@]}" "${setup_command[@]}" </dev/null
else
  runuser -u "$TARGET_USER" -- env -i "${target_env[@]}" "${setup_command[@]}"
  if runuser -u "$TARGET_USER" -- env -i "${target_env[@]}" \
    "$binary_target" --config-dir "$setup_config" sharing-enabled; then
    MODE=share
  else
    MODE=local
  fi
fi

if [[ "$MODE" == local && -e "$setup_config/consent-v6.json" ]]; then
  # A stale or invalid marker is OFF by contract; normalize the temporary
  # config before promoting it to the authoritative root-owned directory.
  rm -f -- "$setup_config/consent-v6.json"
fi

if [[ "$MODE" == share && ! -f "$credential_file" ]] && (( had_consent || had_identity )); then
  fail "sharing is configured but its encrypted key is missing; restore $credential_file before enabling sharing"
fi

[[ -f "$setup_config/settings.json" && ! -L "$setup_config/settings.json" ]] || fail 'setup did not create a regular settings.json'
[[ -f "$setup_config/setup-complete" && ! -L "$setup_config/setup-complete" ]] || fail 'setup did not create a regular setup-complete marker'
if [[ "$MODE" == share ]]; then
  [[ -f "$setup_config/consent-v6.json" && ! -L "$setup_config/consent-v6.json" ]] || fail 'sharing setup did not create the consent marker'
else
  [[ ! -e "$setup_config/consent-v6.json" && ! -L "$setup_config/consent-v6.json" ]] || fail 'local-only setup unexpectedly created a consent marker'
fi

stage_dir=$(mktemp -d "$config_dir/.install.XXXXXXXX")
chmod 0700 "$stage_dir"
for name in settings.json setup-complete; do
  install -o root -g root -m 0644 "$setup_config/$name" "$stage_dir/$name"
done
if [[ "$MODE" == share ]]; then
  install -o root -g root -m 0644 "$setup_config/consent-v6.json" "$stage_dir/consent-v6.json"
fi
for name in settings.json setup-complete; do
  mv -f -- "$stage_dir/$name" "$config_dir/$name"
done
if [[ "$MODE" == share ]]; then
  mv -f -- "$stage_dir/consent-v6.json" "$config_dir/consent-v6.json"
else
  # This is the sole existing user-state file intentionally removed: the
  # authoritative current consent marker, after rejecting symlinks above.
  rm -f -- "$config_dir/consent-v6.json"
fi
rm -rf -- "$stage_dir"
stage_dir=

if [[ "$MODE" == share ]]; then
  install -d -o root -g root -m 0700 "$CREDENTIAL_ROOT"
  "$binary_target" --config-dir "$config_dir" provision-key --output "$credential_file"
  [[ -f "$credential_file" && ! -L "$credential_file" ]] || fail 'encrypted signing key was not created safely'
  chown root:root "$credential_file"
  chmod 0600 "$credential_file"
  [[ -f "$identity_marker" && ! -L "$identity_marker" ]] || fail 'signing identity marker was not created safely'
  chown root:root "$identity_marker"
  chmod 0644 "$identity_marker"
fi

systemctl daemon-reload
service_start_epoch=$(date -u +%s)
if [[ "$MODE" == share ]]; then
  systemctl disable "$local_unit" >/dev/null
  systemctl enable --now "$share_unit"
  selected_unit=$share_unit
  sharing_setting=on
else
  systemctl disable "$share_unit" >/dev/null
  systemctl enable --now "$local_unit"
  selected_unit=$local_unit
  sharing_setting=off
fi
if [[ "$update_checks" == on ]]; then
  systemctl enable --now "$UPDATE_CHECK_TIMER"
else
  systemctl disable --now "$UPDATE_CHECK_TIMER" >/dev/null
fi
active_state=$(systemctl show --property=ActiveState --value "$selected_unit" 2>/dev/null) || fail "could not confirm service state: $selected_unit"
[[ "$active_state" == active ]] || fail "service did not restart and become active: $selected_unit ($active_state)"
version_output=$("$binary_target" --version 2>/dev/null) || fail 'could not verify installed binary version'
installed_version=${version_output#tokrate-headless }
[[ "$version_output" == "tokrate-headless $installed_version" && "$installed_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail 'installed binary returned an invalid version'
if [[ -z "$TEST_ROOT" ]]; then
  main_pid=$(systemctl show --property=MainPID --value "$selected_unit" 2>/dev/null) || fail "could not inspect running process: $selected_unit"
  [[ "$main_pid" =~ ^[1-9][0-9]*$ && -e "/proc/$main_pid/exe" ]] || fail "service has no running Tokrate process: $selected_unit"
  installed_inode=$(stat -Lc '%d:%i' -- "$binary_target") || fail 'could not identify the installed Tokrate binary'
  running_inode=$(stat -Lc '%d:%i' -- "/proc/$main_pid/exe") || fail 'could not identify the running Tokrate process'
  [[ "$running_inode" == "$installed_inode" ]] || fail 'the active service is not running the installed binary'

  heartbeat_ok=0
  for _ in {1..60}; do
    status_output=$(runuser -u "$TARGET_USER" -- "$binary_target" --config-dir "$config_dir" --data-dir "$state_dir" status 2>/dev/null || true)
    if [[ "$status_output" == *"\"version\": \"$installed_version\""* \
       && "$status_output" == *'"monitoring": true'* \
       && "$status_output" == *'"running": true'* ]]; then
      heartbeat_at=$(sed -n 's/^[[:space:]]*"updated_at": "\([^"]*\)".*/\1/p' <<<"$status_output")
      heartbeat_epoch=$(date -u -d "$heartbeat_at" +%s 2>/dev/null || printf '0')
      if [[ "$heartbeat_epoch" =~ ^[0-9]+$ ]] && ((heartbeat_epoch >= service_start_epoch)); then
        heartbeat_ok=1
        break
      fi
    fi
    sleep 0.5
  done
  ((heartbeat_ok == 1)) || fail 'service did not publish a fresh running status for the installed version'

  # Recheck the process identity after the heartbeat in case the unit exited while
  # the status file was being read.
  main_pid_after=$(systemctl show --property=MainPID --value "$selected_unit" 2>/dev/null) || fail "could not confirm service process: $selected_unit"
  [[ "$main_pid_after" == "$main_pid" && -e "/proc/$main_pid_after/exe" ]] || fail 'service stopped before health verification completed'
  running_inode_after=$(stat -Lc '%d:%i' -- "/proc/$main_pid_after/exe") || fail 'could not recheck the running Tokrate process'
  [[ "$running_inode_after" == "$installed_inode" ]] || fail 'service stopped running the installed binary during health verification'
fi
if [[ -n "$previous_binary_version" && "$previous_binary_version" != "$installed_version" ]]; then
  printf 'Updated %s → %s\n' "$previous_binary_version" "$installed_version"
elif [[ -n "$previous_binary_version" ]]; then
  printf 'Already up to date: %s\n' "$installed_version"
else
  printf 'Installed binary version: %s\n' "$installed_version"
fi
printf 'Community sharing configured: %s\n' "$sharing_setting"
printf 'Automatic update checks configured: %s\n' "$update_checks"
printf 'Service restarted and running: %s\n' "$selected_unit"
printf 'Configuration: %s\n' "$config_dir"
printf 'Check status: sudo -u %s -H %s --config-dir %s --data-dir %s status\n' "$TARGET_USER" "$binary_target" "$config_dir" "$state_dir"
