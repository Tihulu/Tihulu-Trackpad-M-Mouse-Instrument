#!/bin/sh
set -eu

APP_ROOT="${NOSPEAKER_STUDIO_APP_ROOT:-$HOME/Applications}"
BIN_ROOT="${NOSPEAKER_STUDIO_BIN_ROOT:-$HOME/.local/bin}"
APP="$APP_ROOT/NoSpeaker Studio.app"
CLI="$BIN_ROOT/nospeaker-studio"

rm -rf "$APP"
rm -f "$CLI"
printf 'Removed NoSpeaker Studio from:\n  %s\n  %s\n' "$APP" "$CLI"
