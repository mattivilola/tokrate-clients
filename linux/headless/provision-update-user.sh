#!/usr/bin/env bash
set -Eeuo pipefail

readonly ACCOUNT=tokrate-update
readonly CONFIG=/usr/lib/sysusers.d/tokrate-update.conf

fail() {
  printf 'tokrate-headless account provisioning: %s\n' "$*" >&2
  exit 1
}

[[ $EUID -eq 0 ]] || fail 'must run as root'
command -v systemd-sysusers >/dev/null || fail 'systemd-sysusers is required'

validate_group() {
  local entry name password gid members
  entry=$(awk -F: -v name="$ACCOUNT" '$1 == name { if (++n > 1) exit 2; print } END { if (n > 1) exit 2 }' /etc/group) \
    || fail 'the local updater group is ambiguous'
  [[ -n "$entry" ]] || return 0
  IFS=: read -r name password gid members <<<"$entry"
  [[ "$name" == "$ACCOUNT" && "$gid" =~ ^[1-9][0-9]{0,2}$ ]] || fail 'the existing updater group is not a system group'
  ((10#$gid <= 999)) || fail 'the existing updater group is not a system group'
  [[ -z "$members" ]] || fail 'the existing updater group has unexpected members'
}

validate_user() {
  local entry name password uid gid gecos home shell group_gid supplemental
  entry=$(awk -F: -v name="$ACCOUNT" '$1 == name { if (++n > 1) exit 2; print } END { if (n > 1) exit 2 }' /etc/passwd) \
    || fail 'the local updater account is ambiguous'
  [[ -n "$entry" ]] || return 0
  IFS=: read -r name password uid gid gecos home shell <<<"$entry"
  [[ "$name" == "$ACCOUNT" && "$uid" =~ ^[1-9][0-9]{0,2}$ ]] || fail 'the existing updater account does not have a system UID'
  ((10#$uid <= 999)) || fail 'the existing updater account does not have a system UID'
  [[ "$home" == /nonexistent && "$shell" == /usr/sbin/nologin && -x "$shell" ]] \
    || fail 'the existing updater account must have no home and a non-login shell'
  group_gid=$(awk -F: -v name="$ACCOUNT" '$1 == name { if (++n > 1) exit 2; print $3 } END { if (n > 1) exit 2 }' /etc/group) \
    || fail 'the local updater group is ambiguous'
  [[ -n "$group_gid" && "$gid" == "$group_gid" ]] || fail 'the updater account must use its dedicated primary group'
  supplemental=$(awk -F: -v name="$ACCOUNT" '$1 != name { n = split($4, members, ","); for (i = 1; i <= n; i++) if (members[i] == name) found = 1 } END { if (found) print "yes" }' /etc/group)
  [[ -z "$supplemental" ]] || fail 'the updater account has unexpected supplementary group membership'
}

validate_local_account() {
  validate_group
  validate_user
}

[[ -f "$CONFIG" && ! -L "$CONFIG" ]] || fail 'the Tokrate sysusers definition is missing or unsafe'
[[ "$(stat -c %u -- "$CONFIG")" == 0 ]] || fail 'the Tokrate sysusers definition must be root-owned'
config_mode=$(stat -c %a -- "$CONFIG") || fail 'could not inspect the Tokrate sysusers definition'
(( (0$config_mode & 022) == 0 )) || fail 'the Tokrate sysusers definition must not be group or world writable'

validate_local_account
if getent passwd "$ACCOUNT" >/dev/null && ! awk -F: -v name="$ACCOUNT" '$1 == name { found = 1 } END { exit !found }' /etc/passwd; then
  fail 'the updater account name is already assigned outside the local passwd database'
fi
if getent group "$ACCOUNT" >/dev/null && ! awk -F: -v name="$ACCOUNT" '$1 == name { found = 1 } END { exit !found }' /etc/group; then
  fail 'the updater group name is already assigned outside the local group database'
fi

systemd-sysusers "$CONFIG"
validate_local_account

entry=$(awk -F: -v name="$ACCOUNT" '$1 == name { print; found = 1 } END { if (!found) exit 1 }' /etc/passwd) \
  || fail 'systemd-sysusers did not create the updater account'
IFS=: read -r _ _ _ gid _ _ _ <<<"$entry"
group_ids=$(id -G "$ACCOUNT") || fail 'could not verify updater group membership'
[[ "$group_ids" == "$gid" ]] || fail 'the updater account has unexpected supplementary group membership'
