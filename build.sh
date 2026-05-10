#!/bin/bash
set -e
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_DIR="$SCRIPT_DIR/MeetingRecorder.app"
CONTENTS="$APP_DIR/Contents"
MACOS="$CONTENTS/MacOS"
RESOURCES="$CONTENTS/Resources"
DMG_PATH="$SCRIPT_DIR/MeetingRecorder.dmg"

rm -rf "$APP_DIR"
mkdir -p "$MACOS" "$RESOURCES"

# Compile Universal Binary (arm64 + x86_64)
echo "Compiling arm64..."
swiftc \
    "$SCRIPT_DIR/AudioRecorder.swift" \
    "$SCRIPT_DIR/MeetingRecorderApp.swift" \
    -o "$MACOS/MeetingRecorder-arm64" \
    -sdk "$(xcrun --show-sdk-path)" \
    -target arm64-apple-macosx15.0 \
    -framework ScreenCaptureKit \
    -framework AVFoundation \
    -framework CoreMedia \
    -framework UserNotifications

echo "Compiling x86_64..."
swiftc \
    "$SCRIPT_DIR/AudioRecorder.swift" \
    "$SCRIPT_DIR/MeetingRecorderApp.swift" \
    -o "$MACOS/MeetingRecorder-x86_64" \
    -sdk "$(xcrun --show-sdk-path)" \
    -target x86_64-apple-macosx15.0 \
    -framework ScreenCaptureKit \
    -framework AVFoundation \
    -framework CoreMedia \
    -framework UserNotifications

echo "Creating Universal Binary..."
lipo -create \
    "$MACOS/MeetingRecorder-arm64" \
    "$MACOS/MeetingRecorder-x86_64" \
    -output "$MACOS/MeetingRecorder"
rm "$MACOS/MeetingRecorder-arm64" "$MACOS/MeetingRecorder-x86_64"

# Bundle resources
cp "$SCRIPT_DIR/Info.plist" "$CONTENTS/Info.plist"
if [ -f "$SCRIPT_DIR/AppIcon.icns" ]; then
    cp "$SCRIPT_DIR/AppIcon.icns" "$RESOURCES/AppIcon.icns"
fi

# Ad-hoc code sign
codesign --force --sign - --entitlements /dev/stdin "$APP_DIR" <<ENTITLEMENTS
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.device.audio-input</key>
    <true/>
    <key>com.apple.security.device.screen-capture</key>
    <true/>
</dict>
</plist>
ENTITLEMENTS

echo "Built: $APP_DIR"

# Create DMG
rm -f "$DMG_PATH"
echo "Creating DMG..."

# Create temp dir with app + Applications symlink
DMG_TMP="$SCRIPT_DIR/.dmg-tmp"
rm -rf "$DMG_TMP"
mkdir -p "$DMG_TMP"
cp -R "$APP_DIR" "$DMG_TMP/"
ln -s /Applications "$DMG_TMP/Applications"

hdiutil create -volname "MeetingRecorder" \
    -srcfolder "$DMG_TMP" \
    -ov -format UDZO \
    "$DMG_PATH" >/dev/null

rm -rf "$DMG_TMP"
echo "DMG: $DMG_PATH"
