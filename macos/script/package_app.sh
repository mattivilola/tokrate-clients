#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CONFIGURATION="${1:-release}"
SWIFT_BUILD=(swift build)
if [[ "${2:-}" == "--disable-sandbox" ]]; then SWIFT_BUILD+=(--disable-sandbox); fi
case "$CONFIGURATION" in debug|release) ;; *) echo 'Expected debug or release' >&2; exit 2;; esac
"${SWIFT_BUILD[@]}" --package-path "$ROOT_DIR" --build-system native -j 2 --configuration "$CONFIGURATION" --product TokrateApp
BIN_DIR="$("${SWIFT_BUILD[@]}" --package-path "$ROOT_DIR" --build-system native --configuration "$CONFIGURATION" --show-bin-path)"
if [[ "$CONFIGURATION" == release ]]; then
    DEFAULT_BUNDLE="$ROOT_DIR/macos/dist/0.1.13/Tokrate.app"
else
    DEFAULT_BUNDLE="$ROOT_DIR/macos/dist/0.1.13-debug/Tokrate.app"
fi
BUNDLE="${TOKRATE_BUNDLE_PATH:-$DEFAULT_BUNDLE}"
SPARKLE_SOURCE="$BIN_DIR/Sparkle.framework"
SPARKLE_LICENSE=""
UPDATER_PUBLIC_KEY=""

if [[ -e "$BUNDLE" || -L "$BUNDLE" ]]; then
    if [[ "$CONFIGURATION" == debug && "$BUNDLE" == "$DEFAULT_BUNDLE" ]]; then
        rm -rf "$BUNDLE"
    else
        echo "Refusing to replace an existing app bundle: $BUNDLE (set TOKRATE_BUNDLE_PATH to a new destination)." >&2
        exit 1
    fi
fi
[[ -d "$SPARKLE_SOURCE" ]] || { echo "Missing Sparkle framework: $SPARKLE_SOURCE" >&2; exit 1; }
for candidate in \
    "$ROOT_DIR/.build/checkouts/Sparkle/LICENSE" \
    "$ROOT_DIR/.build/swiftpm/build/checkouts/Sparkle/LICENSE"; do
    if [[ -f "$candidate" ]]; then SPARKLE_LICENSE="$candidate"; break; fi
done
[[ -n "$SPARKLE_LICENSE" ]] || { echo 'Missing Sparkle license in the resolved SwiftPM checkout.' >&2; exit 1; }

if [[ "$CONFIGURATION" == release ]]; then
    KEY_FILE="$ROOT_DIR/macos/updater-public-key.txt"
    [[ -r "$KEY_FILE" ]] || { echo "Missing updater public key: $KEY_FILE" >&2; exit 1; }
    UPDATER_PUBLIC_KEY="$(tr -d '[:space:]' < "$KEY_FILE")"
    if ! DECODED_KEY_LENGTH="$(printf '%s' "$UPDATER_PUBLIC_KEY" | /usr/bin/base64 -D 2>/dev/null | /usr/bin/wc -c | tr -d '[:space:]')" || [[ "$DECODED_KEY_LENGTH" != 32 ]]; then
        echo "Invalid Sparkle Ed25519 public key in $KEY_FILE (expected base64 encoding of 32 bytes)." >&2
        exit 1
    fi
fi

mkdir -p "$(dirname "$BUNDLE")/" "$BUNDLE/Contents/MacOS"
mkdir -p "$BUNDLE/Contents/Frameworks" "$BUNDLE/Contents/Resources"
cp "$BIN_DIR/TokrateApp" "$BUNDLE/Contents/MacOS/Tokrate"
chmod +x "$BUNDLE/Contents/MacOS/Tokrate"
ditto "$SPARKLE_SOURCE" "$BUNDLE/Contents/Frameworks/Sparkle.framework"
cp "$SPARKLE_LICENSE" "$BUNDLE/Contents/Resources/Sparkle-LICENSE.txt"
"$ROOT_DIR/macos/script/make_app_icon.sh" "$BUNDLE/Contents/Resources/AppIcon.icns"

BINARY="$BUNDLE/Contents/MacOS/Tokrate"
if ! /usr/bin/otool -l "$BINARY" | grep -Fq 'path @executable_path/../Frameworks'; then
    /usr/bin/install_name_tool -add_rpath '@executable_path/../Frameworks' "$BINARY"
fi
while IFS= read -r rpath; do
    case "$rpath" in
        @*|/usr/lib/*|/System/Library/*) ;;
        *) /usr/bin/install_name_tool -delete_rpath "$rpath" "$BINARY" ;;
    esac
done < <(/usr/bin/otool -l "$BINARY" | /usr/bin/awk '/cmd LC_RPATH/ { in_rpath = 1; next } in_rpath && $1 == "path" { print $2; in_rpath = 0 }')
/usr/bin/otool -L "$BINARY" | grep -Fq '@rpath/Sparkle.framework/Versions/B/Sparkle' || {
    echo 'Tokrate is not linked to its bundled Sparkle framework.' >&2
    exit 1
}
if /usr/bin/otool -l "$BINARY" | grep -E 'path /(Users|Applications|private)/|\.build/'; then
    echo 'Tokrate contains a developer-only runtime search path.' >&2
    exit 1
fi
cat > "$BUNDLE/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>Tokrate</string>
<key>CFBundleIdentifier</key><string>dev.tokrate.mac</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundleName</key><string>Tokrate</string>
<key>CFBundleDisplayName</key><string>Tokrate</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.1.13</string>
<key>CFBundleVersion</key><string>14</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>LSUIElement</key><true/>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSHumanReadableCopyright</key><string>Copyright © 2026 Tokrate</string>
<key>SUFeedURL</key><string>https://tokrate.dev/updates/macos/stable.xml</string>
<key>SUEnableAutomaticChecks</key><true/>
<key>SUEnableSystemProfiling</key><false/>
<key>SUAutomaticallyUpdate</key><false/>
<key>SUAllowsAutomaticUpdates</key><false/>
<key>SUVerifyUpdateBeforeExtraction</key><true/>
<key>SURequireSignedFeed</key><true/>
</dict></plist>
PLIST
if [[ "$CONFIGURATION" == release ]]; then
    /usr/libexec/PlistBuddy -c "Add :SUPublicEDKey string $UPDATER_PUBLIC_KEY" "$BUNDLE/Contents/Info.plist"
fi
/usr/bin/plutil -lint "$BUNDLE/Contents/Info.plist"
if [[ "$CONFIGURATION" == debug ]]; then
    SPARKLE_BUNDLE="$BUNDLE/Contents/Frameworks/Sparkle.framework"
    if [[ -f "$SPARKLE_BUNDLE/Versions/B/Autoupdate" ]]; then
        /usr/bin/codesign --force --sign - --preserve-metadata=entitlements "$SPARKLE_BUNDLE/Versions/B/Autoupdate"
    fi
    while IFS= read -r -d '' nested_bundle; do
        /usr/bin/codesign --force --sign - --preserve-metadata=entitlements "$nested_bundle"
    done < <(find "$SPARKLE_BUNDLE/Versions/B" -mindepth 1 -depth -type d \
        \( -name '*.app' -o -name '*.xpc' -o -name '*.framework' \) -print0)
    /usr/bin/codesign --force --sign - --preserve-metadata=entitlements "$SPARKLE_BUNDLE"
    /usr/bin/codesign --force --sign - "$BUNDLE"
    /usr/bin/codesign --verify --deep --strict --verbose=2 "$BUNDLE"
fi
echo "Built $BUNDLE ($CONFIGURATION; $(uname -m)). Sparkle is embedded; signing and notarization are separate release steps."
