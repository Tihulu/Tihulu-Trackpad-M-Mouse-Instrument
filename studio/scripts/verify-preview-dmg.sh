#!/bin/sh
# Read-only preview DMG inspection. Never installs, launches or kills an app.
set -eu
fail() { printf '%s\n' "Preview verification: $*" >&2; exit 1; }
[ "$#" -eq 3 ] || fail "usage: verify-preview-dmg.sh DMG CHECKSUM EXPECTED_CHECKOUT_SHA"
[ "$(uname -s)" = Darwin ] || fail "macOS is required"
DMG=$1
SUM=$2
EXPECTED_SHA=$3
case "$EXPECTED_SHA" in *[!0-9a-f]*|'') fail "invalid checkout SHA";; esac
[ "${#EXPECTED_SHA}" -eq 40 ] || fail "invalid checkout SHA length"
[ -f "$DMG" ] && [ -f "$SUM" ] || fail "missing artifact or checksum"
NAME=$(basename "$DMG")
[ "$NAME" = "Tihulu-0.3.0-preview.dmg" ] || fail "unexpected artifact name"
EXPECTED=$(awk -v name="$NAME" 'NF == 2 && $2 == name {print $1}' "$SUM")
ACTUAL=$(shasum -a 256 "$DMG" | awk '{print $1}')
[ "$EXPECTED" = "$ACTUAL" ] || fail "checksum mismatch"
hdiutil verify "$DMG" >/dev/null
MOUNT=$(mktemp -d "${TMPDIR:-/tmp}/tihulu-preview-check.XXXXXX")
cleanup() {
    if [ "$MOUNTED" = yes ]; then
        hdiutil detach "$MOUNT" -quiet || { echo "Could not detach preview inspection mount: $MOUNT" >&2; return 1; }
    fi
    rmdir "$MOUNT"
}
MOUNTED=no
# Preserve a verification failure; also fail a successful inspection when
# detach or removal fails. A plain EXIT trap returning 1 is not sufficient.
finish() {
    status=$?
    trap - EXIT
    cleanup || status=1
    exit "$status"
}
trap finish EXIT
trap 'exit 1' HUP INT TERM
hdiutil attach "$DMG" -readonly -nobrowse -mountpoint "$MOUNT" -quiet
MOUNTED=yes
APP="$MOUNT/Tihulu Trackpad & M. Mouse Instrument Preview.app"
[ -d "$APP" ] && [ ! -L "$APP" ] || fail "missing isolated preview app"
[ ! -e "$MOUNT/Tihulu Trackpad & M. Mouse Instrument.app" ] || fail "stable app present in preview image"
PLIST="$APP/Contents/Info.plist"
plist() { /usr/libexec/PlistBuddy -c "Print :$1" "$PLIST"; }
plutil -lint "$PLIST"
[ "$(plist CFBundleIdentifier)" = com.tihulu.trackpadmmouseinstrument.preview ] || fail "wrong bundle identifier"
[ "$(plist TIHULUBuildChannel)" = preview ] || fail "wrong build channel"
[ "$(plist CFBundleShortVersionString)" = 0.3.0 ] || fail "wrong version"
[ "$(plist NoSpeakerBuildSHA)" = "$EXPECTED_SHA" ] || fail "wrong checkout commit"
[ "$(plist CFBundleDisplayName)" = "Tihulu Trackpad & M. Mouse Instrument Preview" ] || fail "wrong display name"
[ -x "$APP/Contents/MacOS/NoSpeakerStudio" ] || fail "missing executable"
[ -s "$APP/Contents/Resources/TihuluInstrument.icns" ] || fail "missing icon"
codesign --verify --deep --strict --verbose=2 "$APP"
# Successful inspection still requires a successful detach.
trap - EXIT
cleanup || exit 1
printf 'Verified isolated preview bundle at checkout %s\n' "$EXPECTED_SHA"
