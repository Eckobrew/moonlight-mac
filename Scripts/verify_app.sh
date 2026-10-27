#!/bin/bash
set -euo pipefail
APP_DIR="${1:?Usage: verify_app.sh /path/to/Moonlight.app}"
PLIST="$APP_DIR/Contents/Info.plist"
plutil -lint "$PLIST"
# Public-IP serverinfo uses HTTP. These narrower keys override the global
# exception by their presence, including when their value is false.
[[ "$(/usr/libexec/PlistBuddy -c 'Print NSAppTransportSecurity:NSAllowsArbitraryLoads' "$PLIST")" == true ]] || {
    echo "GameStream HTTP requires NSAllowsArbitraryLoads" >&2; exit 1;
}
for override in NSAllowsLocalNetworking NSAllowsArbitraryLoadsForMedia NSAllowsArbitraryLoadsInWebContent; do
    if /usr/libexec/PlistBuddy -c "Print NSAppTransportSecurity:$override" "$PLIST" >/dev/null 2>&1; then
        echo "ATS key $override overrides GameStream's HTTP exception" >&2; exit 1
    fi
done
EXECUTABLE="$(/usr/libexec/PlistBuddy -c 'Print CFBundleExecutable' "$PLIST")"
[[ "$EXECUTABLE" == moonlight-mac ]] || { echo "Unexpected app executable name: $EXECUTABLE" >&2; exit 1; }
[[ -x "$APP_DIR/Contents/MacOS/$EXECUTABLE" ]] || { echo "App executable is missing" >&2; exit 1; }
FILE_TYPE="$(file -b "$APP_DIR/Contents/MacOS/$EXECUTABLE")"
[[ "$FILE_TYPE" == *Mach-O* ]] || { echo "App executable is not Mach-O" >&2; exit 1; }
RESOURCE_BUNDLE="$APP_DIR/Contents/Resources/MoonlightMac_MoonlightMac.bundle"
[[ -d "$RESOURCE_BUNDLE" ]] || { echo "SwiftPM resources are missing" >&2; exit 1; }
[[ -f "$RESOURCE_BUNDLE/Shaders.metal" || -f "$RESOURCE_BUNDLE/default.metallib" ]] || {
    echo "Metal shader resource is missing" >&2; exit 1;
}
for language in en de fr es; do
    STRINGS="$RESOURCE_BUNDLE/$language.lproj/Localizable.strings"
    [[ -s "$STRINGS" ]] || { echo "Missing language resources: $language" >&2; exit 1; }
    plutil -lint "$STRINGS"
done
for license in LICENSE THIRD_PARTY_NOTICES.md moonlight-common-c.txt enet.txt nanors.txt opus.txt; do
    [[ -s "$APP_DIR/Contents/Resources/Licenses/$license" ]] || { echo "Missing license: $license" >&2; exit 1; }
done
codesign --verify --deep --strict --verbose=2 "$APP_DIR"
echo "Verified executable, Metal and language resources, licenses, transport policy, plist and signature."
