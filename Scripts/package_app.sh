#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

echo "==> Building Moonlight for macOS in Release mode..."
cd "$PROJECT_DIR"

TMPDIR=/tmp \
CLANG_MODULE_CACHE_PATH=/tmp/clang-cache \
SWIFT_MODULE_CACHE_PATH=/tmp/swift-cache \
swift build -c release --disable-sandbox \
  -Xswiftc -module-cache-path -Xswiftc /tmp/swift-cache \
  -Xcc -fmodules-cache-path=/tmp/clang-cache

# Locate binary and resources
RELEASE_DIR=$(swift build -c release --show-bin-path)
BIN_PATH="$RELEASE_DIR/MoonlightMac"

if [ ! -f "$BIN_PATH" ]; then
    echo "Error: Binary not found at $BIN_PATH"
    exit 1
fi

APP_NAME="Moonlight.app"
OUTPUT_DIR="$PROJECT_DIR/Products"
APP_DIR="$OUTPUT_DIR/$APP_NAME"

echo "==> Assembling $APP_NAME bundle..."
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"

# 1. Executable
cp "$BIN_PATH" "$APP_DIR/Contents/MacOS/MoonlightMac"
chmod +x "$APP_DIR/Contents/MacOS/MoonlightMac"

# 2. Info.plist & PkgInfo
cp "$PROJECT_DIR/Resources/Info.plist" "$APP_DIR/Contents/Info.plist"
echo -n "APPL????" > "$APP_DIR/Contents/PkgInfo"

# 3. App Icon
if [ -f "$PROJECT_DIR/Resources/AppIcon.icns" ]; then
    cp "$PROJECT_DIR/Resources/AppIcon.icns" "$APP_DIR/Contents/Resources/AppIcon.icns"
fi

# 4. SPM Resource Bundles (Metal Shaders, Assets)
if [ -d "$RELEASE_DIR/MoonlightMac_MoonlightMac.bundle" ]; then
    cp -R "$RELEASE_DIR/MoonlightMac_MoonlightMac.bundle" "$APP_DIR/Contents/Resources/"
fi

# 5. Ad-hoc Code Signing
echo "==> Applying ad-hoc code signature and entitlements..."
codesign --force --deep --sign - \
  --entitlements "$PROJECT_DIR/Resources/MoonlightMac.entitlements" \
  "$APP_DIR"

echo "==> Verifying signature..."
codesign -vvv --deep --strict "$APP_DIR"

echo ""
echo "=========================================================="
echo "  Success! Application packaged successfully:"
echo "  $APP_DIR"
echo "=========================================================="
echo ""
echo "To launch the app:"
echo "  open \"$APP_DIR\""
echo ""
echo "To install in Applications:"
echo "  cp -R \"$APP_DIR\" /Applications/"
echo ""
