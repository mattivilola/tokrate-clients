#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
MODE="${1:-run}"
case "$MODE" in run|--debug|--logs|--telemetry|--verify) ;; *) echo 'usage: build_and_run.sh [--debug|--logs|--telemetry|--verify]' >&2; exit 2;; esac
pkill -x Tokrate >/dev/null 2>&1 || true
"$ROOT_DIR/macos/script/package_app.sh" debug
BUNDLE="${TOKRATE_BUNDLE_PATH:-$ROOT_DIR/macos/dist/0.1.15-debug/Tokrate.app}"
case "$MODE" in
  --debug) lldb -- "$BUNDLE/Contents/MacOS/Tokrate" ;;
  --logs|--telemetry) /usr/bin/open -n "$BUNDLE"; /usr/bin/log stream --info --style compact --predicate 'process == "Tokrate"' ;;
  --verify) /usr/bin/open -n "$BUNDLE"; sleep 1; pgrep -x Tokrate >/dev/null ;;
  *) /usr/bin/open -n "$BUNDLE" ;;
esac
