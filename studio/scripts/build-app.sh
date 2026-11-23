#!/bin/sh
set -eu
cd "$(dirname "$0")/.."

[ "$(uname -s)" = "Darwin" ] || { echo "NoSpeaker Studio.app can only be built on macOS." >&2; exit 1; }
command -v swift >/dev/null 2>&1 || { echo "Swift is required. Install Xcode or Apple Command Line Tools." >&2; exit 1; }
command -v codesign >/dev/null 2>&1 || { echo "codesign is required." >&2; exit 1; }

echo "==> Tests"
swift test

echo "==> Release build"
swift build -c release
BIN_DIR=$(swift build -c release --show-bin-path)
BIN="$BIN_DIR/NoSpeakerStudio"
[ -x "$BIN" ] || { echo "Release binary not found at $BIN" >&2; exit 1; }

APP="dist/NoSpeaker Studio.app"
CONTENTS="$APP/Contents"
MACOS="$CONTENTS/MacOS"
RESOURCES="$CONTENTS/Resources"
rm -rf "$APP"
mkdir -p "$MACOS" "$RESOURCES"
cp "$BIN" "$MACOS/NoSpeakerStudio"
cp LICENSE NOTICE ATTRIBUTION.md "$RESOURCES/"

cat > "$CONTENTS/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDisplayName</key><string>NoSpeaker Studio</string>
    <key>CFBundleExecutable</key><string>NoSpeakerStudio</string>
    <key>CFBundleIdentifier</key><string>com.tihulu.nospeakerstudio</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundleName</key><string>NoSpeaker Studio</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSHumanReadableCopyright</key><string>NoSpeaker Studio downstream work; based on nospeaker by Cody Collier (MIT).</string>
</dict>
</plist>
PLIST

# Ad-hoc signing makes local development launches predictable. Distribution uses release-sign.sh.
codesign --force --deep --sign - "$APP"
echo "Built: $APP"
