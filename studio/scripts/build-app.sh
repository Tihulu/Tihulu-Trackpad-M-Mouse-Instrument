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

APP="dist/Tihulu Trackpad & M. Mouse Instrument.app"
CONTENTS="$APP/Contents"
MACOS="$CONTENTS/MacOS"
RESOURCES="$CONTENTS/Resources"
rm -rf "$APP"
mkdir -p "$MACOS" "$RESOURCES"
cp "$BIN" "$MACOS/NoSpeakerStudio"
cp LICENSE NOTICE ATTRIBUTION.md "$RESOURCES/"
ICON_SOURCE="Resources/TihuluTrackpadMouseIcon.svg"
if [ -f "$ICON_SOURCE" ]; then
    cp "$ICON_SOURCE" "$RESOURCES/TihuluTrackpadMouseIcon.svg"
    if command -v rsvg-convert >/dev/null 2>&1 && command -v iconutil >/dev/null 2>&1; then
        echo "==> Rendering the approved TIHULU vector icon"
        ICONSET="$(mktemp -d "${TMPDIR:-/tmp}/tihulu-icon.XXXXXX").iconset"
        mkdir -p "$ICONSET"
        rsvg-convert --width 1024 --height 1024 "$ICON_SOURCE" > "$ICONSET/icon_512x512@2x.png"
        for spec in "16 16x16" "32 16x16@2x" "32 32x32" "64 32x32@2x" "128 128x128" "256 128x128@2x" "256 256x256" "512 256x256@2x" "512 512x512"; do
            set -- $spec
            sips --resampleWidthHeight "$1" "$1" "$ICONSET/icon_512x512@2x.png" --out "$ICONSET/icon_$2.png" >/dev/null
        done
        iconutil -c icns "$ICONSET" -o "$RESOURCES/TihuluInstrument.icns"
        rm -rf "$ICONSET"
    else
        echo "==> SVG logo bundled; install librsvg (rsvg-convert) to generate a macOS .icns during local builds."
    fi
fi

cat > "$CONTENTS/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDisplayName</key><string>Tihulu Trackpad &amp; M. Mouse Instrument</string>
    <key>CFBundleExecutable</key><string>NoSpeakerStudio</string>
    <key>CFBundleIdentifier</key><string>com.tihulu.trackpadmmouseinstrument</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundleName</key><string>Tihulu Trackpad Instrument</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.2.0</string>
    <key>CFBundleVersion</key><string>2</string>
    <key>NoSpeakerBuildSHA</key><string>$BUILD_SHA</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>CFBundleIconFile</key><string>TihuluInstrument.icns</string>
    <key>NSHumanReadableCopyright</key><string>TIHULU downstream work; based on nospeaker by Cody Collier (MIT).</string>
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
