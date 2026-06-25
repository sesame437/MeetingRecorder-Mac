#!/bin/bash
set -e
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

# Neutralize global git `url.git@github.com:.insteadof` rewrite — SPM clones
# over HTTPS and would otherwise fail on machines without a loaded SSH key.
export GIT_CONFIG_GLOBAL=/dev/null

APP_DIR="$SCRIPT_DIR/MeetingRecorder.app"
CONTENTS="$APP_DIR/Contents"
MACOS="$CONTENTS/MacOS"
RESOURCES="$CONTENTS/Resources"
DMG_PATH="$SCRIPT_DIR/MeetingRecorder.dmg"

# 0. Auto-bump CalVer in Info.plist to today's date
VERSION=$(date +"%Y.%-m.%-d")
sed -i '' "s|<string>[0-9]*\.[0-9]*\.[0-9]*</string>|<string>${VERSION}</string>|g" "$SCRIPT_DIR/Info.plist"
echo "Version: $VERSION"

# 1. Build arm64 release (Apple Silicon only, per user preference)
echo "Building arm64 release..."
swift build -c release --arch arm64

# 2. Assemble .app bundle
rm -rf "$APP_DIR"
mkdir -p "$MACOS" "$RESOURCES"

ARM64_BIN=".build/arm64-apple-macosx/release/MeetingRecorder"
cp "$ARM64_BIN" "$MACOS/MeetingRecorder"

cp "$SCRIPT_DIR/Info.plist" "$CONTENTS/Info.plist"
if [ -f "$SCRIPT_DIR/AppIcon.icns" ]; then
    cp "$SCRIPT_DIR/AppIcon.icns" "$RESOURCES/AppIcon.icns"
fi

# 3. Ad-hoc sign
codesign --force --sign - --entitlements /dev/stdin "$APP_DIR" <<ENTITLEMENTS
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.device.audio-input</key>
    <true/>
    <key>com.apple.security.device.screen-capture</key>
    <true/>
    <key>com.apple.security.network.client</key>
    <true/>
</dict>
</plist>
ENTITLEMENTS

echo "Built: $APP_DIR"

# 4. DMG
rm -f "$DMG_PATH"
DMG_TMP="$SCRIPT_DIR/.dmg-tmp"
rm -rf "$DMG_TMP"
mkdir -p "$DMG_TMP"
cp -R "$APP_DIR" "$DMG_TMP/"
ln -s /Applications "$DMG_TMP/Applications"
hdiutil create -volname "MeetingRecorder" -srcfolder "$DMG_TMP" -ov -format UDZO "$DMG_PATH" >/dev/null
rm -rf "$DMG_TMP"
echo "DMG: $DMG_PATH"
