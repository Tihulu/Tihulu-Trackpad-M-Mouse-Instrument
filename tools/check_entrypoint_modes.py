#!/usr/bin/env python3
"""Verify tracked executable modes without changing the checkout."""
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
ENTRYPOINTS = (
    "build.sh", "play.sh", "install-studio.sh", "uninstall-studio.sh",
    "studio/scripts/build-app.sh", "studio/scripts/release-sign.sh",
    "studio/scripts/verify-preview-dmg.sh", "studio/scripts/verify.sh",
)


def main():
    raw = subprocess.check_output(
        ["git", "-C", str(ROOT), "ls-tree", "-r", "-z", "HEAD"])
    modes = {}
    for entry in raw.split(b"\0"):
        if entry:
            metadata, name = entry.split(b"\t", 1)
            modes[name.decode("utf-8")] = metadata.split()[0].decode("ascii")
    errors = []
    for path in ENTRYPOINTS:
        if modes.get(path) != "100755":
            errors.append(f"{path}: expected Git mode 100755, got {modes.get(path)}")
        if not (ROOT / path).is_file() or (ROOT / path).is_symlink():
            errors.append(f"{path}: missing or not a regular file")
    if errors:
        print("\n".join(errors), file=sys.stderr)
        return 1
    print(f"Verified {len(ENTRYPOINTS)} tracked executable entrypoints.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
