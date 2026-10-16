#!/usr/bin/env bash
set -Eeuo pipefail

readonly TOKRATE_VERSION=0.1.28
readonly RELEASE_TAG="v${TOKRATE_VERSION}-headless-alpha.1"
readonly RELEASE_BASE="https://github.com/mattivilola/tokrate-clients/releases/download/${RELEASE_TAG}"
# SHA-256 pins for the native Debian release archives.
readonly SHA256_AMD64='93a4e3b06ce7835a1b6cbbd4320495259f355f944451a00ccca0154ef95e437a'
readonly SHA256_ARM64='ff8ab3e5bbcadaa36c05a600ba997b7979766173c125d07c2bf37c95fe95ba9d'

usage() {
  cat <<'EOF'
Install Tokrate Headless on Debian 12 or newer.

Usage: curl -fsSL https://tokrate.dev/install-headless.sh | bash
       curl -fsSL https://tokrate.dev/install-headless.sh | bash -s -- --user USER
       curl -fsSL https://tokrate.dev/install-headless.sh | bash -s -- [--share | --local-only]

Non-root runs install for the current account and require sudo. Root runs must
name the non-root account with --user. Without a mode, setup asks once.
EOF
}

fail() {
  printf 'tokrate-headless bootstrap: %s\n' "$*" >&2
  exit 1
}

target_user=
mode=
while (($#)); do
  case "$1" in
    --user)
      (($# >= 2)) || fail '--user requires a username'
      [[ -z "$target_user" ]] || fail '--user may be specified only once'
      target_user=$2
      shift 2
      ;;
    --share)
      [[ -z "$mode" ]] || fail 'choose only one of --share or --local-only'
      mode=--share
      shift
      ;;
    --local-only)
      [[ -z "$mode" ]] || fail 'choose only one of --share or --local-only'
      mode=--local-only
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *) fail "unknown option: $1" ;;
  esac
done

if ((EUID == 0)); then
  [[ -n "$target_user" ]] || fail 'root must pass --user USER explicitly'
else
  caller_user=$(id -un) || fail 'could not determine the current account'
  if [[ -z "$target_user" ]]; then
    target_user=$caller_user
  elif [[ "$target_user" != "$caller_user" ]]; then
    fail 'a non-root run can install only for the current account'
  fi
  command -v sudo >/dev/null || fail 'sudo is required when running as a non-root user'
fi

[[ "$target_user" =~ ^[a-zA-Z_][a-zA-Z0-9_.-]*\$?$ ]] || fail 'username contains unsupported characters'

[[ -r /etc/os-release ]] || fail 'cannot identify the operating system'
# shellcheck disable=SC1091
. /etc/os-release
[[ "${ID:-}" == debian && "${VERSION_ID:-}" =~ ^([0-9]+)(\..*)?$ ]] || fail 'this installer supports Debian 12 or newer'
debian_major=${BASH_REMATCH[1]}
((10#$debian_major >= 12)) || fail 'this installer supports Debian 12 or newer'

for command_name in curl sha256sum tar dpkg mktemp; do
  command -v "$command_name" >/dev/null || fail "required command not found: $command_name"
done

architecture=$(dpkg --print-architecture)
case "$architecture" in
  amd64)
    asset="tokrate-headless_${TOKRATE_VERSION}_amd64.tar.gz"
    expected_sha=$SHA256_AMD64
    ;;
  arm64)
    asset="tokrate-headless_${TOKRATE_VERSION}_arm64.tar.gz"
    expected_sha=$SHA256_ARM64
    ;;
  *) fail "unsupported Debian architecture: $architecture (supported: amd64, arm64)" ;;
esac
[[ "$expected_sha" =~ ^[[:xdigit:]]{64}$ ]] || fail "the pinned ${architecture} release hash has not been configured"

find_current_service() {
  running_unit=
  active_unit=
  for service_mode in local share; do
    unit="tokrate-headless-${service_mode}@${target_user}.service"
    if systemctl is-active --quiet "$unit"; then
      active_unit=$unit
      service_pid=$(systemctl show --property=MainPID --value "$unit") || service_pid=
      if [[ "$service_pid" =~ ^[1-9][0-9]*$ && "/proc/$service_pid/exe" -ef "$installed_binary" ]]; then
        running_unit=$unit
        return
      fi
    fi
  done
}

installed_version=
installed_binary=/usr/bin/tokrate-headless
if [[ -f "$installed_binary" && ! -L "$installed_binary" && -x "$installed_binary" ]] \
  && [[ $(stat -c %u "$installed_binary") == 0 ]]; then
  installed_mode=$(stat -c %a "$installed_binary")
  if [[ "$installed_mode" =~ ^[0-7]{3,4}$ ]] && (( (8#$installed_mode & 0022) == 0 )); then
    installed_output=$("$installed_binary" --version) || installed_output=
    if [[ "$installed_output" =~ ^tokrate-headless\ ([0-9]+\.[0-9]+\.[0-9]+)$ ]]; then
      installed_version=${BASH_REMATCH[1]}
    fi
  fi
fi
if [[ -n "$installed_version" ]] && dpkg --compare-versions "$installed_version" gt "$TOKRATE_VERSION"; then
  printf 'Installed Tokrate Headless %s is newer than this installer (%s). No changes made.\n' "$installed_version" "$TOKRATE_VERSION"
  exit 0
fi
checker_setup_needed=
if dpkg --compare-versions "$TOKRATE_VERSION" ge 0.1.28 && [[ ! -f /etc/tokrate-headless/update-checks ]]; then
  checker_setup_needed=1
fi
if [[ "$installed_version" == "$TOKRATE_VERSION" && -z "$mode$checker_setup_needed" \
  && -f "/etc/tokrate-headless/$target_user/setup-complete" \
  && -f "/etc/tokrate-headless/$target_user/settings.json" ]]; then
  find_current_service
  if [[ -n "$running_unit" ]]; then
    printf 'Already up to date: Tokrate Headless %s. No download or restart needed.\n' "$installed_version"
    printf 'Service is running the installed version: %s.\n' "$running_unit"
    exit 0
  elif [[ -z "$active_unit" ]]; then
    printf 'Already up to date: Tokrate Headless %s. No changes made.\n' "$installed_version"
    printf 'No collector service is running for %s. Check systemctl status before collecting.\n' "$target_user"
    exit 0
  fi
  printf 'Tokrate Headless %s is installed, but the service is using an older binary. Repairing the service.\n' "$installed_version"
fi
if [[ "$installed_version" == "$TOKRATE_VERSION" ]]; then
  printf 'Applying service configuration for installed Tokrate Headless %s.\n' "$TOKRATE_VERSION"
elif [[ -n "$installed_version" ]]; then
  printf 'Updating Tokrate Headless %s → %s for %s.\n' "$installed_version" "$TOKRATE_VERSION" "$target_user"
else
  printf 'Installing Tokrate Headless %s for %s.\n' "$TOKRATE_VERSION" "$target_user"
fi

if [[ -z "$mode" && ( ! -r /dev/tty || ! -w /dev/tty ) ]]; then
  fail 'an interactive terminal is required unless --share or --local-only is supplied'
fi

work_dir=$(mktemp -d "/tmp/tokrate-headless-bootstrap.XXXXXXXX")
root_work=
cleanup() {
  if [[ -n "${root_work:-}" && "$root_work" == /tmp/tokrate-headless-bootstrap-root.* && -d "$root_work" && ! -L "$root_work" ]]; then
    if ((EUID == 0)); then
      rm -rf -- "$root_work"
    else
      sudo -n rm -rf -- "$root_work" >/dev/null 2>&1 || true
    fi
  fi
  if [[ -n "${work_dir:-}" && "$work_dir" == /tmp/tokrate-headless-bootstrap.* && -d "$work_dir" && ! -L "$work_dir" ]]; then
    rm -rf -- "$work_dir"
  fi
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM

archive="$work_dir/$asset"
printf 'Downloading Tokrate Headless %s for %s…\n' "$TOKRATE_VERSION" "$architecture"
curl --fail --silent --show-error --location --output "$archive" "${RELEASE_BASE}/${asset}"
printf '%s  %s\n' "$expected_sha" "$archive" | sha256sum --check --status || fail 'release archive SHA-256 did not match the pinned value'

bundle_root=$work_dir
if ((EUID != 0)); then
  # Copy and verify again in a root-owned directory before any downloaded code
  # is executed with privileges. A concurrent user process cannot replace it.
  root_work=$(sudo mktemp -d "/tmp/tokrate-headless-bootstrap-root.XXXXXXXX")
  [[ "$root_work" == /tmp/tokrate-headless-bootstrap-root.* ]] || fail 'sudo returned an unsafe staging path'
  sudo install -o root -g root -m 0600 "$archive" "$root_work/$asset"
  printf '%s  %s\n' "$expected_sha" "$root_work/$asset" | sudo sha256sum --check --status || fail 'root-staged archive SHA-256 did not match the pinned value'
  sudo tar --extract --gzip --file "$root_work/$asset" --directory "$root_work" --no-same-owner --no-same-permissions
  sudo chmod 0755 "$root_work"
  bundle_root=$root_work
else
  tar --extract --gzip --file "$archive" --directory "$work_dir" --no-same-owner --no-same-permissions
  chmod 0755 "$work_dir"
fi
bundle="$bundle_root/tokrate-headless"
installer="$bundle/install.sh"
binary="$bundle/tokrate-headless"
[[ -d "$bundle" && ! -L "$bundle" ]] || fail 'release archive did not contain the expected bundle directory'
[[ -f "$installer" && ! -L "$installer" && -x "$installer" ]] || fail 'release archive is missing a safe executable installer'
[[ -f "$binary" && ! -L "$binary" && -x "$binary" ]] || fail 'release archive is missing a safe executable binary'

install_command=("$installer" --user "$target_user" --binary "$binary")
[[ -z "$mode" ]] || install_command+=("$mode")
source_env=()
if ((EUID != 0)); then
  source_env+=("SUDO_USER=$caller_user")
elif [[ -n "${SUDO_USER:-}" ]]; then
  source_env+=("SUDO_USER=$SUDO_USER")
fi
for env_name in CODEX_HOME CLAUDE_CONFIG_DIR GROK_HOME KIMI_CODE_HOME XDG_CONFIG_HOME XDG_DATA_HOME; do
  env_value=${!env_name-}
  [[ -n "$env_value" ]] && source_env+=("${env_name}=${env_value}")
done

if ((EUID == 0)); then
  if [[ -z "$mode" ]]; then
    env "${source_env[@]}" "${install_command[@]}" </dev/tty
  else
    env "${source_env[@]}" "${install_command[@]}" </dev/null
  fi
else
  if [[ -z "$mode" ]]; then
    sudo env "${source_env[@]}" "${install_command[@]}" </dev/tty
  else
    sudo env "${source_env[@]}" "${install_command[@]}" </dev/null
  fi
fi

verified_version=$("$installed_binary" --version) || fail 'Installer finished, but the installed binary could not report its version'
[[ "$verified_version" == "tokrate-headless $TOKRATE_VERSION" ]] || fail "Installer finished, but version $TOKRATE_VERSION was not installed"
for attempt in {1..10}; do
  find_current_service
  [[ -z "$running_unit" ]] || break
  sleep 0.5
done
[[ -n "$running_unit" ]] || fail "Version $TOKRATE_VERSION is installed, but the service could not be verified running that binary; check systemctl status"
if [[ -z "$installed_version" ]]; then
  printf 'Installed Tokrate Headless %s; service started and running: %s.\n' "$TOKRATE_VERSION" "$running_unit"
elif [[ "$installed_version" == "$TOKRATE_VERSION" ]]; then
  printf 'Tokrate Headless %s confirmed; service restarted and running: %s.\n' "$TOKRATE_VERSION" "$running_unit"
else
  printf 'Updated Tokrate Headless %s → %s; service restarted and running: %s.\n' "$installed_version" "$TOKRATE_VERSION" "$running_unit"
fi
