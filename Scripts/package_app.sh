#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CONFIGURATION="${1:-release}"
case "$CONFIGURATION" in
    release|debug) ;;
    *) echo "Usage: $0 [release|debug]" >&2; exit 2 ;;
esac
cd "$PROJECT_DIR"

BUILD_PATH="${MOONLIGHT_BUILD_PATH:-$PROJECT_DIR/.build}"
CACHE_ROOT="${TMPDIR:-/tmp}/moonlight-build-cache"
mkdir -p "$CACHE_ROOT/clang" "$CACHE_ROOT/swift"
export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-$CACHE_ROOT/clang}"
export SWIFTPM_MODULECACHE_OVERRIDE="${SWIFTPM_MODULECACHE_OVERRIDE:-$CACHE_ROOT/swift}"
BUILD_ARGS=(-c "$CONFIGURATION" --scratch-path "$BUILD_PATH" --disable-sandbox --jobs "${MOONLIGHT_BUILD_JOBS:-4}")

echo "==> Building Moonlight ($CONFIGURATION)..."
swift build "${BUILD_ARGS[@]}"
RELEASE_DIR="$(swift build "${BUILD_ARGS[@]}" --show-bin-path)"
BIN_PATH="$RELEASE_DIR/moonlight-mac"
RESOURCE_BUNDLE="$RELEASE_DIR/MoonlightMac_MoonlightMac.bundle"
[[ -x "$BIN_PATH" ]] || { echo "Missing executable: $BIN_PATH" >&2; exit 1; }
[[ -d "$RESOURCE_BUNDLE" ]] || { echo "Missing SwiftPM resource bundle: $RESOURCE_BUNDLE" >&2; exit 1; }

OUTPUT_DIR="$PROJECT_DIR/Products"
APP_DIR="$OUTPUT_DIR/Moonlight.app"
mkdir -p "$OUTPUT_DIR"
# Assemble in a new directory so a failed build/sign leaves the previous app intact.
STAGING="$(mktemp -d "$OUTPUT_DIR/.moonlight-package.XXXXXX")"
trap 'rm -rf "$STAGING"' EXIT
STAGED_APP="$STAGING/Moonlight.app"
mkdir -p "$STAGED_APP/Contents/MacOS" "$STAGED_APP/Contents/Resources/Licenses"
cp "$BIN_PATH" "$STAGED_APP/Contents/MacOS/moonlight-mac"
cp "$PROJECT_DIR/Resources/Info.plist" "$STAGED_APP/Contents/Info.plist"
printf 'APPL????' > "$STAGED_APP/Contents/PkgInfo"
cp "$PROJECT_DIR/Resources/AppIcon.icns" "$STAGED_APP/Contents/Resources/"
cp -R "$RESOURCE_BUNDLE" "$STAGED_APP/Contents/Resources/"
LICENSES="$STAGED_APP/Contents/Resources/Licenses"
cp LICENSE THIRD_PARTY_NOTICES.md "$LICENSES/"
cp Sources/MoonlightCommonC/LICENSE.txt "$LICENSES/moonlight-common-c.txt"
cp Sources/MoonlightCommonC/enet/LICENSE "$LICENSES/enet.txt"
cp Sources/MoonlightCommonC/nanors/LICENSE "$LICENSES/nanors.txt"
cp Sources/Copus/COPYING "$LICENSES/opus.txt"

IDENTITY="${MOONLIGHT_SIGNING_IDENTITY:--}"
SIGN_ARGS=(--force --sign "$IDENTITY")
if [[ "$IDENTITY" != "-" ]]; then
    SIGN_ARGS+=(--options runtime --timestamp)
fi
codesign "${SIGN_ARGS[@]}" "$STAGED_APP"
"$SCRIPT_DIR/verify_app.sh" "$STAGED_APP"

if [[ -n "${MOONLIGHT_NOTARY_PROFILE:-}" ]]; then
    [[ "$IDENTITY" != "-" ]] || { echo "Notarization requires a Developer ID signing identity." >&2; exit 1; }
    ditto -c -k --keepParent "$STAGED_APP" "$STAGING/Moonlight.zip"
    xcrun notarytool submit "$STAGING/Moonlight.zip" --keychain-profile "$MOONLIGHT_NOTARY_PROFILE" --wait
    xcrun stapler staple "$STAGED_APP"
    xcrun stapler validate "$STAGED_APP"
    spctl --assess --type execute --verbose "$STAGED_APP"
fi
rm -rf "$APP_DIR"
mv "$STAGED_APP" "$APP_DIR"
echo "Packaged and verified: $APP_DIR"
