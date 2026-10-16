#!/usr/bin/env bash
set -Eeuo pipefail

script_dir=$(cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(cd -- "$script_dir/../.." && pwd)
manifest="$script_dir/Cargo.toml"
out_dir=${1:-"$repo_root/dist/headless"}
target_dir=${CARGO_TARGET_DIR:-"$script_dir/target"}
if [[ "$target_dir" != /* ]]; then
  target_dir="$PWD/$target_dir"
fi
export CARGO_TARGET_DIR="$target_dir"

for command_name in cargo dpkg-deb dpkg-architecture mktemp; do
  command -v "$command_name" >/dev/null || {
    printf 'package.sh: required command not found: %s\n' "$command_name" >&2
    exit 1
  }
done

version=$(sed -n 's/^version = "\([^"]*\)"$/\1/p' "$manifest" | head -n 1)
[[ "$version" =~ ^[0-9][A-Za-z0-9.+:~_-]*$ ]] || {
  printf 'package.sh: invalid Cargo package version: %s\n' "$version" >&2
  exit 1
}

architecture=$(dpkg-architecture -qDEB_HOST_ARCH)
case "$(uname -m)" in
  x86_64|aarch64) ;;
  *) printf 'package.sh: unsupported build architecture: %s\n' "$(uname -m)" >&2; exit 1 ;;
esac

cargo build --locked --release --manifest-path "$manifest"
binary="$target_dir/release/tokrate-headless"
[[ -x "$binary" && -f "$binary" ]] || {
  printf 'package.sh: Cargo did not produce %s\n' "$binary" >&2
  exit 1
}

mkdir -p -- "$out_dir"
deb="$out_dir/tokrate-headless_${version}_${architecture}.deb"
[[ ! -e "$deb" && ! -L "$deb" ]] || {
  printf 'package.sh: refusing to overwrite existing package: %s\n' "$deb" >&2
  exit 1
}
stage=$(mktemp -d "${TMPDIR:-/tmp}/tokrate-headless-deb.XXXXXXXX")
cleanup() {
  if [[ -n "${stage:-}" && "$stage" == "${TMPDIR:-/tmp}"/tokrate-headless-deb.* && -d "$stage" && ! -L "$stage" ]]; then
    rm -rf -- "$stage"
  fi
}
trap cleanup EXIT

install -d -m 0755 "$stage/DEBIAN" "$stage/usr/bin" "$stage/lib/systemd/system"
install -m 0755 "$binary" "$stage/usr/bin/tokrate-headless"
install -m 0644 "$script_dir/tokrate-headless-local@.service" "$stage/lib/systemd/system/tokrate-headless-local@.service"
install -m 0644 "$script_dir/tokrate-headless-share@.service" "$stage/lib/systemd/system/tokrate-headless-share@.service"
install -m 0644 "$script_dir/tokrate-headless-update-check.service" "$stage/lib/systemd/system/tokrate-headless-update-check.service"
install -m 0644 "$script_dir/tokrate-headless-update-check.timer" "$stage/lib/systemd/system/tokrate-headless-update-check.timer"
cat >"$stage/DEBIAN/control" <<EOF
Package: tokrate-headless
Version: $version
Section: net
Priority: optional
Architecture: $architecture
Depends: libc6 (>= 2.36), libgcc-s1, systemd (>= 252)
Maintainer: Tokrate maintainers
Description: Local coding-session speed monitor for headless Linux servers
 Tokrate Headless monitors supported local coding-tool session logs. Sharing
 is opt-in and managed by a separate systemd service.
EOF
cat >"$stage/DEBIAN/postinst" <<'EOF'
#!/bin/sh
set -e
# Loading unit definitions does not enable or start either service. The
# administrator must run the installer and explicitly choose a consent mode.
if [ -d /run/systemd/system ] && command -v systemctl >/dev/null 2>&1; then
  systemctl daemon-reload
fi
exit 0
EOF
chmod 0755 "$stage/DEBIAN/postinst"

dpkg-deb --root-owner-group --build "$stage" "$deb"
printf 'Created %s\n' "$deb"
