#!/usr/bin/env bash
# Builds AppIcon.icns from the Tokrate mark. Usage: make_app_icon.sh <output.icns>
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OUTPUT="${1:?Usage: make_app_icon.sh OUTPUT.icns}"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/tokrate-icon.XXXXXX")"
cleanup() {
    rm -f "$WORK"/render_app_icon "$WORK"/AppIcon.iconset/*.png "$WORK"/*.tiff
    rmdir "$WORK/AppIcon.iconset" "$WORK" 2>/dev/null || true
}
trap cleanup EXIT
/usr/bin/swiftc -O "$ROOT_DIR/macos/script/render_app_icon.swift" -o "$WORK/render_app_icon"
"$WORK/render_app_icon" "$WORK/AppIcon.iconset"
if ! /usr/bin/iconutil -c icns -o "$OUTPUT" "$WORK/AppIcon.iconset"; then
    # Some macOS toolchain builds reject a valid iconset emitted by AppKit. Keep the same sizes
    # and pixels, then let the system TIFF encoder assemble the ICNS container.
    rm -f "$OUTPUT"
    TIFF_IMAGES=()
    for png in "$WORK"/AppIcon.iconset/*.png; do
        tiff="$WORK/$(basename "${png%.png}").tiff"
        /usr/bin/sips -s format tiff "$png" --out "$tiff" >/dev/null
        TIFF_IMAGES+=("$tiff")
    done
    /usr/bin/tiffutil -catnosizecheck "${TIFF_IMAGES[@]}" -out "$WORK/AppIcon.tiff"
    /usr/bin/tiff2icns "$WORK/AppIcon.tiff" "$OUTPUT"
fi
