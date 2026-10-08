#!/usr/bin/env bash
# Signs an already-built bundle. Notarization runs only with an explicit profile argument.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
IDENTITY="${1:?Usage: sign_release.sh CODE_SIGN_IDENTITY [KEYCHAIN_NOTARY_PROFILE]}"
NOTARY_PROFILE="${2:-}"
BUNDLE="${TOKRATE_BUNDLE_PATH:-$ROOT_DIR/macos/dist/0.1.20/Tokrate.app}"
BINARY="$BUNDLE/Contents/MacOS/Tokrate"
SPARKLE_FRAMEWORK="$BUNDLE/Contents/Frameworks/Sparkle.framework"
[[ -x "$BINARY" ]] || { echo 'Run package_app.sh release first.' >&2; exit 1; }
[[ -d "$SPARKLE_FRAMEWORK" ]] || { echo 'The packaged app is missing Sparkle.framework.' >&2; exit 1; }
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$BUNDLE/Contents/Info.plist")"
ARCH="$(/usr/bin/lipo -archs "$BINARY")"
case "$ARCH" in arm64|x86_64) ;; *) echo "Expected one verified release architecture, got: $ARCH" >&2; exit 1;; esac
ARCHIVE="$ROOT_DIR/macos/dist/Tokrate-$VERSION-macos-$ARCH.zip"
[[ ! -e "$ARCHIVE" ]] || { echo "Refusing to replace an existing release archive: $ARCHIVE" >&2; exit 1; }
/usr/bin/plutil -lint "$BUNDLE/Contents/Info.plist"

# Sparkle ships helper executables with entitlements. Sign leaf code first,
# preserving those entitlements, then sign each nested bundle from inside out.
while IFS= read -r -d '' executable; do
    if /usr/bin/file -b "$executable" | grep -q 'Mach-O'; then
        /usr/bin/codesign --force --options runtime --timestamp --sign "$IDENTITY" \
            --preserve-metadata=entitlements "$executable"
    fi
done < <(find "$SPARKLE_FRAMEWORK/Versions/B" -type f -perm -111 -print0)

while IFS= read -r -d '' nested_bundle; do
    /usr/bin/codesign --force --options runtime --timestamp --sign "$IDENTITY" \
        --preserve-metadata=entitlements "$nested_bundle"
done < <(find "$SPARKLE_FRAMEWORK/Versions/B" -mindepth 1 -depth -type d \
    \( -name '*.app' -o -name '*.xpc' -o -name '*.framework' \) -print0)

/usr/bin/codesign --force --options runtime --timestamp --sign "$IDENTITY" \
    --preserve-metadata=entitlements "$SPARKLE_FRAMEWORK"
/usr/bin/codesign --force --options runtime --timestamp --sign "$IDENTITY" "$BUNDLE"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$BUNDLE"
/usr/bin/codesign --display --verbose=4 "$BUNDLE"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$BUNDLE" "$ARCHIVE"
if [[ -n "$NOTARY_PROFILE" ]]; then
    xcrun notarytool submit "$ARCHIVE" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$BUNDLE"
    xcrun stapler validate "$BUNDLE"
    /usr/sbin/spctl --assess --type execute --verbose=2 "$BUNDLE"
    /usr/bin/codesign --verify --deep --strict --verbose=2 "$BUNDLE"
    /usr/bin/ditto -c -k --sequesterRsrc --keepParent "$BUNDLE" "$ARCHIVE"
else
    echo 'Signed only. This archive has not been notarized or stapled.'
fi
/usr/bin/shasum -a 256 "$ARCHIVE"
echo "Release archive: $ARCHIVE"
