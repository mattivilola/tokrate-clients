#!/usr/bin/env bash
# Builds AppIcon.icns from the Tokrate mark. Usage: make_app_icon.sh <output.icns>
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OUTPUT="${1:?Usage: make_app_icon.sh OUTPUT.icns}"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/tokrate-icon.XXXXXX")"
cleanup() {
    rm -f "$WORK"/render_app_icon "$WORK"/AppIcon.iconset/*.png
    rmdir "$WORK/AppIcon.iconset" "$WORK" 2>/dev/null || true
}
trap cleanup EXIT
/usr/bin/swiftc -O "$ROOT_DIR/macos/script/render_app_icon.swift" -o "$WORK/render_app_icon"
"$WORK/render_app_icon" "$WORK/AppIcon.iconset"
/usr/bin/iconutil -c icns -o "$OUTPUT" "$WORK/AppIcon.iconset"
