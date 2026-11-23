#!/bin/sh
set -eu

REPO="Tihulu/Tihulu-Trackpad-M-Mouse-Instrument"
REF="${NOSPEAKER_STUDIO_REF:-main}"
APP_NAME="Tihulu Trackpad & M. Mouse Instrument.app"
APP_ROOT="${NOSPEAKER_STUDIO_APP_ROOT:-$HOME/Applications}"
APP_DEST="$APP_ROOT/$APP_NAME"
BIN_ROOT="${NOSPEAKER_STUDIO_BIN_ROOT:-$HOME/.local/bin}"
CLI_DEST="$BIN_ROOT/tihulu-trackpad-instrument"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/nospeaker-studio.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT HUP INT TERM

fail() {
    printf '\nNoSpeaker Studio installer: %s\n\n' "$1" >&2
    exit 1
}

[ "$(uname -s)" = "Darwin" ] || fail "macOS is required."

MACOS_MAJOR="$(sw_vers -productVersion | awk -F. '{print $1}')"
[ "$MACOS_MAJOR" -ge 13 ] || fail "macOS 13 or later is required."

command -v curl >/dev/null 2>&1 || fail "curl is required."
command -v ditto >/dev/null 2>&1 || fail "ditto is required."

mkdir -p "$APP_ROOT" "$BIN_ROOT"

install_app() {
    SRC_APP="$1"
    [ -d "$SRC_APP" ] || fail "The app bundle was not found after preparation."

    # A running macOS process keeps executing the old mapped binary even after the
    # app bundle on disk is replaced. Stop it first so reopening always launches
    # the freshly installed build.
    pkill -x NoSpeakerStudio 2>/dev/null || true
    sleep 0.2

    rm -rf "$APP_DEST"
    ditto "$SRC_APP" "$APP_DEST"

    cat > "$CLI_DEST" <<EOF
#!/bin/sh
exec "$APP_DEST/Contents/MacOS/NoSpeakerStudio" "\$@"
EOF
    chmod +x "$CLI_DEST"

    INSTALLED_SHA="$(/usr/libexec/PlistBuddy -c 'Print :NoSpeakerBuildSHA' "$APP_DEST/Contents/Info.plist" 2>/dev/null || true)"
    printf '\nInstalled Tihulu Trackpad & M. Mouse Instrument:\n  App: %s\n  CLI: %s\n' "$APP_DEST" "$CLI_DEST"
    if [ -n "$INSTALLED_SHA" ]; then
        printf '  Build: %s\n' "$INSTALLED_SHA"
    fi
    printf '\nOpen it now with:\n  open "%s"\n\n' "$APP_DEST"
}

printf 'Tihulu Trackpad & M. Mouse Instrument installer\n'
printf 'Repository: https://github.com/%s\n' "$REPO"
printf 'Install destination: %s\n\n' "$APP_DEST"

# Prefer an explicitly published DMG. Source builds remain available through
# TIHULU_INSTRUMENT_CHANNEL=source (for development or the newest main head).
CHANNEL="${TIHULU_INSTRUMENT_CHANNEL:-release}"
if [ "$CHANNEL" = "release" ]; then
    RELEASE_URL="https://github.com/$REPO/releases/latest/download/Tihulu-Trackpad-M-Mouse-Instrument-macOS.dmg"
    if curl -fL --retry 2 --connect-timeout 10 "$RELEASE_URL" -o "$TMP/release.dmg" 2>/dev/null; then
        printf 'Installing the latest macOS DMG release...\n'
        mkdir -p "$TMP/mounted"
        hdiutil attach "$TMP/release.dmg" -readonly -nobrowse -mountpoint "$TMP/mounted" -quiet \
            || fail "Cannot mount the downloaded DMG."
        RELEASE_APP="$TMP/mounted/$APP_NAME"
        if [ ! -d "$RELEASE_APP" ]; then
            hdiutil detach "$TMP/mounted" -quiet 2>/dev/null || true
            fail "The release DMG does not contain $APP_NAME."
        fi
        install_app "$RELEASE_APP"
        hdiutil detach "$TMP/mounted" -quiet 2>/dev/null || true
        exit 0
    fi
    printf 'No packaged DMG release was found.\n'
elif [ "$CHANNEL" != "source" ]; then
    fail "Invalid TIHULU_INSTRUMENT_CHANNEL: choose release or source."
fi

printf 'Building from exact source commit.\n'
printf 'This fallback requires Apple Command Line Tools or Xcode.\n\n'

if ! xcode-select -p >/dev/null 2>&1 || ! command -v swift >/dev/null 2>&1; then
    fail "Apple Command Line Tools are required for the source-build fallback. Install them with: xcode-select --install"
fi

COMMIT_JSON="$(curl -fsSL --retry 2 --connect-timeout 10 "https://api.github.com/repos/$REPO/commits/$REF" 2>/dev/null || true)"
SOURCE_SHA="$(printf '%s\n' "$COMMIT_JSON" | sed -n 's/^[[:space:]]*"sha":[[:space:]]*"\([0-9a-f][0-9a-f]*\)".*/\1/p' | head -n 1)"
[ "${#SOURCE_SHA}" -eq 40 ] || fail "Could not resolve source ref '$REF' to an exact Git commit."

printf 'Resolved source ref %s -> %s\n' "$REF" "$SOURCE_SHA"
ARCHIVE_URL="https://codeload.github.com/$REPO/tar.gz/$SOURCE_SHA"
if ! curl -fL --retry 2 --connect-timeout 10 "$ARCHIVE_URL" -o "$TMP/source.tar.gz"; then
    fail "Could not download exact source commit '$SOURCE_SHA' from GitHub."
fi

mkdir -p "$TMP/source"
tar -xzf "$TMP/source.tar.gz" -C "$TMP/source"
SOURCE_ROOT="$(find "$TMP/source" -mindepth 1 -maxdepth 1 -type d -print -quit)"
[ -n "$SOURCE_ROOT" ] || fail "The source archive could not be unpacked."
[ -x "$SOURCE_ROOT/studio/scripts/build-app.sh" ] || fail "The downloaded ref does not contain TIHULU Studio."

(
    cd "$SOURCE_ROOT/studio"
    NOSPEAKER_STUDIO_SKIP_TESTS=1 NOSPEAKER_STUDIO_BUILD_SHA="$SOURCE_SHA" ./scripts/build-app.sh
)

install_app "$SOURCE_ROOT/studio/dist/$APP_NAME"
