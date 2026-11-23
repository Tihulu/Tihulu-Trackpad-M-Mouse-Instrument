#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
APP="dist/NoSpeaker Studio.app"
IDENTITY=${DEVELOPER_ID_APPLICATION:-}
PROFILE=${NOTARY_PROFILE:-nospeaker-studio}

[ "$(uname -s)" = "Darwin" ] || { echo "Release signing requires macOS." >&2; exit 1; }
[ -d "$APP" ] || { echo "Build the app first with scripts/build-app.sh." >&2; exit 1; }
[ -n "$IDENTITY" ] || { echo "Set DEVELOPER_ID_APPLICATION to your Developer ID Application identity." >&2; exit 1; }

codesign --force --deep --options runtime --timestamp --sign "$IDENTITY" "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"
mkdir -p dist
rm -f dist/NoSpeaker-Studio-macOS.zip
ditto -c -k --keepParent "$APP" dist/NoSpeaker-Studio-macOS.zip
xcrun notarytool submit dist/NoSpeaker-Studio-macOS.zip --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$APP"
echo "Signed, notarized and stapled: $APP"
