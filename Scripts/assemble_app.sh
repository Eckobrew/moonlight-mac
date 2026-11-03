#!/bin/bash
set -euo pipefail

# This script is called either during Xcode's "Assemble App Bundle" build phase
# or standalone to package Moonlight.app.

SRCROOT="${SRCROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
CONFIGURATION="${CONFIGURATION:-Debug}"
TARGET_BUILD_DIR="${TARGET_BUILD_DIR:-$SRCROOT/Products}"
CONTENTS_FOLDER_PATH="${CONTENTS_FOLDER_PATH:-Moonlight.app/Contents}"
BUILT_PRODUCTS_DIR="${BUILT_PRODUCTS_DIR:-$TARGET_BUILD_DIR}"

APP_CONTENTS="$TARGET_BUILD_DIR/$CONTENTS_FOLDER_PATH"
APP_DIR="$(dirname "$APP_CONTENTS")"
MACOS_DIR="$APP_CONTENTS/MacOS"
RESOURCES_DIR="$APP_CONTENTS/Resources"
LICENSES_DIR="$RESOURCES_DIR/Licenses"

mkdir -p "$MACOS_DIR" "$RESOURCES_DIR" "$LICENSES_DIR"

# 1. Locate or build the moonlight-mac executable
BIN_SRC=""
if [[ -x "$BUILT_PRODUCTS_DIR/moonlight-mac" ]]; then
    BIN_SRC="$BUILT_PRODUCTS_DIR/moonlight-mac"
elif [[ -x "$SRCROOT/.build/debug/moonlight-mac" && "$CONFIGURATION" == "Debug" ]]; then
    BIN_SRC="$SRCROOT/.build/debug/moonlight-mac"
elif [[ -x "$SRCROOT/.build/release/moonlight-mac" && "$CONFIGURATION" == "Release" ]]; then
    BIN_SRC="$SRCROOT/.build/release/moonlight-mac"
else
    # Build it with swift build if not found in built products
    CONFIG_LOWER="$(echo "$CONFIGURATION" | tr '[:upper:]' '[:lower:]')"
    echo "==> Building moonlight-mac ($CONFIG_LOWER)..."
    swift build -c "$CONFIG_LOWER" --scratch-path "$SRCROOT/.build"
    RELEASE_DIR="$(swift build -c "$CONFIG_LOWER" --scratch-path "$SRCROOT/.build" --show-bin-path)"
    BIN_SRC="$RELEASE_DIR/moonlight-mac"
fi

if [[ ! -x "$BIN_SRC" ]]; then
    echo "Error: Could not find or build moonlight-mac executable at $BIN_SRC" >&2
    exit 1
fi

echo "==> Using executable: $BIN_SRC"
cp "$BIN_SRC" "$MACOS_DIR/moonlight-mac"
chmod +x "$MACOS_DIR/moonlight-mac"

# 2. Locate or copy the resource bundle
BUNDLE_SRC=""
CONFIG_LOWER="$(echo "$CONFIGURATION" | tr '[:upper:]' '[:lower:]')"
if [[ -d "$BUILT_PRODUCTS_DIR/MoonlightMac_MoonlightMac.bundle" ]]; then
    BUNDLE_SRC="$BUILT_PRODUCTS_DIR/MoonlightMac_MoonlightMac.bundle"
elif [[ -d "$SRCROOT/.build/$CONFIG_LOWER/MoonlightMac_MoonlightMac.bundle" ]]; then
    BUNDLE_SRC="$SRCROOT/.build/$CONFIG_LOWER/MoonlightMac_MoonlightMac.bundle"
else
    FOUND_BUNDLE="$(find "$SRCROOT/.build" -path "*/$CONFIG_LOWER/*" -name "MoonlightMac_MoonlightMac.bundle" -type d 2>/dev/null | head -n 1 || true)"
    if [[ -z "$FOUND_BUNDLE" ]]; then
        FOUND_BUNDLE="$(find "$SRCROOT/.build" -name "MoonlightMac_MoonlightMac.bundle" -type d 2>/dev/null | head -n 1 || true)"
    fi
    if [[ -n "$FOUND_BUNDLE" && -d "$FOUND_BUNDLE" ]]; then
        BUNDLE_SRC="$FOUND_BUNDLE"
    fi
fi

if [[ -n "$BUNDLE_SRC" && -d "$BUNDLE_SRC" ]]; then
    echo "==> Copying resource bundle from $BUNDLE_SRC"
    rm -rf "$RESOURCES_DIR/MoonlightMac_MoonlightMac.bundle"
    cp -R "$BUNDLE_SRC" "$RESOURCES_DIR/"
else
    echo "Warning: MoonlightMac_MoonlightMac.bundle not found yet" >&2
fi

# Ensure Shaders.metal is also copied into the bundle
DEST_BUNDLE="$RESOURCES_DIR/MoonlightMac_MoonlightMac.bundle"
if [[ -d "$DEST_BUNDLE" ]]; then
    if [[ -f "$SRCROOT/Sources/MoonlightMac/Pipeline/Metal/Shaders.metal" ]]; then
        cp "$SRCROOT/Sources/MoonlightMac/Pipeline/Metal/Shaders.metal" "$DEST_BUNDLE/"
        if [[ -d "$DEST_BUNDLE/Contents/Resources" ]]; then
            cp "$SRCROOT/Sources/MoonlightMac/Pipeline/Metal/Shaders.metal" "$DEST_BUNDLE/Contents/Resources/"
        fi
    fi
    if [[ -f "$DEST_BUNDLE/Contents/Resources/default.metallib" && ! -f "$DEST_BUNDLE/default.metallib" ]]; then
        cp "$DEST_BUNDLE/Contents/Resources/default.metallib" "$DEST_BUNDLE/"
    fi
fi

# 3. Copy AppIcon.icns
if [[ -f "$SRCROOT/Resources/AppIcon.icns" ]]; then
    cp "$SRCROOT/Resources/AppIcon.icns" "$RESOURCES_DIR/"
fi

# 4. Copy Licenses
cp "$SRCROOT/LICENSE" "$LICENSES_DIR/"
cp "$SRCROOT/THIRD_PARTY_NOTICES.md" "$LICENSES_DIR/"
cp "$SRCROOT/Sources/MoonlightCommonC/LICENSE.txt" "$LICENSES_DIR/moonlight-common-c.txt"
cp "$SRCROOT/Sources/MoonlightCommonC/enet/LICENSE" "$LICENSES_DIR/enet.txt"
cp "$SRCROOT/Sources/MoonlightCommonC/nanors/LICENSE" "$LICENSES_DIR/nanors.txt"
cp "$SRCROOT/Sources/Copus/COPYING" "$LICENSES_DIR/opus.txt"

# 5. Mirror to Products/Moonlight.app
if [[ "$TARGET_BUILD_DIR" != "$SRCROOT/Products" ]]; then
    mkdir -p "$SRCROOT/Products"
    rm -rf "$SRCROOT/Products/Moonlight.app"
    cp -R "$APP_DIR" "$SRCROOT/Products/Moonlight.app"
    codesign --force --sign - "$SRCROOT/Products/Moonlight.app" 2>/dev/null || true
fi

codesign --force --sign - "$APP_DIR" 2>/dev/null || true

echo "==> Assembled Moonlight.app structure at $APP_DIR"
