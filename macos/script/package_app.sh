#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CONFIGURATION="${1:-release}"
SWIFT_BUILD=(swift build)
if [[ "${2:-}" == "--disable-sandbox" ]]; then SWIFT_BUILD+=(--disable-sandbox); fi
case "$CONFIGURATION" in debug|release) ;; *) echo 'Expected debug or release' >&2; exit 2;; esac
"${SWIFT_BUILD[@]}" --package-path "$ROOT_DIR" --build-system native -j 2 --configuration "$CONFIGURATION" --product TokrateApp
BIN_DIR="$("${SWIFT_BUILD[@]}" --package-path "$ROOT_DIR" --build-system native --configuration "$CONFIGURATION" --show-bin-path)"
BUNDLE="$ROOT_DIR/macos/dist/Tokrate.app"
mkdir -p "$BUNDLE/Contents/MacOS"
rm -rf "$BUNDLE/Contents/_CodeSignature"
rm -f "$BUNDLE/Contents/CodeResources"
cp "$BIN_DIR/TokrateApp" "$BUNDLE/Contents/MacOS/Tokrate"
chmod +x "$BUNDLE/Contents/MacOS/Tokrate"
cat > "$BUNDLE/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>Tokrate</string>
<key>CFBundleIdentifier</key><string>dev.tokrate.mac</string>
<key>CFBundleName</key><string>Tokrate</string>
<key>CFBundleDisplayName</key><string>Tokrate</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.1.7</string>
<key>CFBundleVersion</key><string>8</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>LSUIElement</key><true/>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSHumanReadableCopyright</key><string>Copyright © 2026 Tokrate</string>
</dict></plist>
PLIST
/usr/bin/plutil -lint "$BUNDLE/Contents/Info.plist"
echo "Built $BUNDLE ($CONFIGURATION; $(uname -m)). Signing and notarization are separate release steps."
