#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ARCHIVE="${1:?Usage: generate_appcast.sh SIGNED_RELEASE.zip EMPTY_OUTPUT_DIRECTORY}"
OUTPUT_DIR="${2:?Usage: generate_appcast.sh SIGNED_RELEASE.zip EMPTY_OUTPUT_DIRECTORY}"
SPARKLE_GENERATE_APPCAST="${SPARKLE_GENERATE_APPCAST:-$ROOT_DIR/../tokrate-app/.local/sparkle-tools/bin/generate_appcast}"

[[ -f "$ARCHIVE" ]] || { echo "Release archive not found: $ARCHIVE" >&2; exit 1; }
[[ -x "$SPARKLE_GENERATE_APPCAST" ]] || {
    echo "Sparkle generate_appcast executable not found: $SPARKLE_GENERATE_APPCAST" >&2
    exit 1
}

ARCHIVE="$(cd "$(dirname "$ARCHIVE")" && pwd)/$(basename "$ARCHIVE")"
ARCHIVE_NAME="$(basename "$ARCHIVE")"
if [[ ! "$ARCHIVE_NAME" =~ ^Tokrate-([0-9]+\.[0-9]+\.[0-9]+)-macos-(arm64|x86_64)\.zip$ ]]; then
    echo "Expected a signed Tokrate release archive named Tokrate-VERSION-macos-ARCH.zip, got: $ARCHIVE_NAME" >&2
    exit 1
fi
VERSION="${BASH_REMATCH[1]}"

mkdir -p "$OUTPUT_DIR"
OUTPUT_DIR="$(cd "$OUTPUT_DIR" && pwd)"
if [[ -n "$(find "$OUTPUT_DIR" -mindepth 1 -maxdepth 1 -print -quit)" ]]; then
    echo "Output directory must be empty so generate_appcast cannot prune or rewrite unrelated files: $OUTPUT_DIR" >&2
    exit 1
fi

cp "$ARCHIVE" "$OUTPUT_DIR/$ARCHIVE_NAME"
DOWNLOAD_URL_PREFIX="https://github.com/mattivilola/tokrate-clients/releases/download/v$VERSION/"
"$SPARKLE_GENERATE_APPCAST" \
    --account dev.tokrate.mac.updates \
    --download-url-prefix "$DOWNLOAD_URL_PREFIX" \
    "$OUTPUT_DIR"

echo "Signed appcast generated in $OUTPUT_DIR. Review its stable.xml and update archive before publishing; this script does not upload or publish files."
