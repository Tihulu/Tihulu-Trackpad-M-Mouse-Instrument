#!/bin/sh
set -eu

REPO="Tihulu/nospeaker"
REF="${NOSPEAKER_STUDIO_REF:-main}"
APP_NAME="NoSpeaker Studio.app"
APP_ROOT="${NOSPEAKER_STUDIO_APP_ROOT:-$HOME/Applications}"
APP_DEST="$APP_ROOT/$APP_NAME"
BIN_ROOT="${NOSPEAKER_STUDIO_BIN_ROOT:-$HOME/.local/bin}"
CLI_DEST="$BIN_ROOT/nospeaker-studio"
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
    rm -rf "$APP_DEST"
    ditto "$SRC_APP" "$APP_DEST"

    cat > "$CLI_DEST" <<EOF
#!/bin/sh
exec "$APP_DEST/Contents/MacOS/NoSpeakerStudio" "\$@"
EOF
    chmod +x "$CLI_DEST"

    printf '\nInstalled NoSpeaker Studio:\n  App: %s\n  CLI: %s\n\n' "$APP_DEST" "$CLI_DEST"
    printf 'Open it now with:\n  open "%s"\n\n' "$APP_DEST"
}

printf 'NoSpeaker Studio installer\n'
printf 'Repository: https://github.com/%s\n' "$REPO"
printf 'Install destination: %s\n\n' "$APP_DEST"

# Prefer a signed/notarized release when one exists.
RELEASE_URL="https://github.com/$REPO/releases/latest/download/NoSpeaker-Studio-macOS.zip"
if curl -fL --retry 2 --connect-timeout 10 "$RELEASE_URL" -o "$TMP/release.zip" 2>/dev/null; then
    printf 'Installing the latest release...\n'
    mkdir -p "$TMP/release"
    ditto -x -k "$TMP/release.zip" "$TMP/release"
    RELEASE_APP="$(find "$TMP/release" -maxdepth 3 -type d -name "$APP_NAME" -print -quit)"
    [ -n "$RELEASE_APP" ] || fail "The release archive did not contain $APP_NAME."
    install_app "$RELEASE_APP"
    exit 0
fi

printf 'No packaged release is available yet; building from source instead.\n'
printf 'This fallback requires Apple Command Line Tools or Xcode.\n\n'

if ! xcode-select -p >/dev/null 2>&1 || ! command -v swift >/dev/null 2>&1; then
    fail "Apple Command Line Tools are required for the source-build fallback. Install them with: xcode-select --install"
fi

ARCHIVE_URL="https://github.com/$REPO/archive/refs/heads/$REF.tar.gz"
if ! curl -fL --retry 2 --connect-timeout 10 "$ARCHIVE_URL" -o "$TMP/source.tar.gz"; then
    fail "Could not download source ref '$REF' from GitHub."
fi

mkdir -p "$TMP/source"
tar -xzf "$TMP/source.tar.gz" -C "$TMP/source"
SOURCE_ROOT="$(find "$TMP/source" -mindepth 1 -maxdepth 1 -type d -print -quit)"
[ -n "$SOURCE_ROOT" ] || fail "The source archive could not be unpacked."
[ -x "$SOURCE_ROOT/studio/scripts/build-app.sh" ] || fail "The downloaded ref does not contain NoSpeaker Studio."

(
    cd "$SOURCE_ROOT/studio"
    ./scripts/build-app.sh
)

install_app "$SOURCE_ROOT/studio/dist/$APP_NAME"
