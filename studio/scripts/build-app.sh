#!/bin/sh
set -eu
cd "$(dirname "$0")/.."

[ "$(uname -s)" = "Darwin" ] || { echo "NoSpeaker Studio.app can only be built on macOS." >&2; exit 1; }
command -v swift >/dev/null 2>&1 || { echo "Swift is required. Install Xcode or Apple Command Line Tools." >&2; exit 1; }
command -v codesign >/dev/null 2>&1 || { echo "codesign is required." >&2; exit 1; }

BUILD_SHA="${NOSPEAKER_STUDIO_BUILD_SHA:-unknown}"

if [ "${NOSPEAKER_STUDIO_SKIP_TESTS:-0}" = "1" ]; then
    echo "==> Tests skipped for installer build"
else
    echo "==> Tests"
    swift test
fi

echo "==> Release build"
if ! swift build -c release; then
    echo >&2
    echo "NoSpeaker Studio release build failed." >&2
    echo "Developer directory: $(xcode-select -p 2>/dev/null || echo unavailable)" >&2
    echo "SDK path: $(xcrun --sdk macosx --show-sdk-path 2>/dev/null || echo unavailable)" >&2
    echo >&2
    echo "If Command Line Tools are incomplete, install/update Xcode or reinstall the tools:" >&2
    echo "  xcode-select --install" >&2
    echo >&2
    exit 1
fi

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

cat > "$CONTENTS/Info.plist" <<PLIST
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
    <key>NoSpeakerBuildSHA</key><string>$BUILD_SHA</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSHumanReadableCopyright</key><string>NoSpeaker Studio downstream work; based on nospeaker by Cody Collier (MIT).</string>
</dict>
</plist>
PLIST

# Prefer a stable local Apple Development identity so macOS TCC permissions
# survive rebuilds. Fall back to ad-hoc signing when no development identity exists.
SIGNING_IDENTITY="${NOSPEAKER_STUDIO_SIGNING_IDENTITY:-}"
if [ -z "$SIGNING_IDENTITY" ]; then
    SIGNING_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | sed -n 's/.*"\(Apple Development: [^"]*\)".*/\1/p' | head -n 1)"
fi

if [ -n "$SIGNING_IDENTITY" ]; then
    echo "==> Signing with stable identity: $SIGNING_IDENTITY"
    codesign --force --deep --sign "$SIGNING_IDENTITY" "$APP"
else
    echo "==> No Apple Development identity found; using ad-hoc signing"
    echo "    Screen & System Audio permission may need to be granted again after rebuilds."
    codesign --force --deep --sign - "$APP"
fi

echo "Built: $APP"
