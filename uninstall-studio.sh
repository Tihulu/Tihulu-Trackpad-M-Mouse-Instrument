#!/bin/sh
set -eu

APP_ROOT="${NOSPEAKER_STUDIO_APP_ROOT:-$HOME/Applications}"
BIN_ROOT="${NOSPEAKER_STUDIO_BIN_ROOT:-$HOME/.local/bin}"
APP="$APP_ROOT/Tihulu Trackpad & M. Mouse Instrument.app"
CLI="$BIN_ROOT/tihulu-trackpad-instrument"

rm -rf "$APP"
# Preserve the separate legacy NoSpeaker Studio app for user-controlled rollback.
# Remove it manually if it is no longer needed.
rm -f "$CLI"
printf 'Removed Tihulu Trackpad & M. Mouse Instrument from:\n  %s\n  %s\n' "$APP" "$CLI"
