#!/usr/bin/env python3
"""Verify tracked executable modes without changing the checkout."""
import os
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
ENTRYPOINTS = (
    "build.sh", "play.sh", "install-studio.sh", "uninstall-studio.sh",
    "studio/scripts/build-app.sh", "studio/scripts/release-sign.sh",
    "studio/scripts/verify-preview-dmg.sh", "studio/scripts/verify.sh",
)


def check(root):
    raw = subprocess.check_output(
        ["git", "-C", str(root), "ls-tree", "-r", "-z", "HEAD", "--", *ENTRYPOINTS])
    modes = {}
    for entry in raw.split(b"\0"):
        if entry:
            metadata, name = entry.split(b"\t", 1)
            modes[name] = metadata.split()[0].decode("ascii")
    errors = []
    for path in ENTRYPOINTS:
        mode = modes.get(os.fsencode(path))
        if mode != "100755":
            errors.append(f"{path}: expected Git mode 100755, got {mode}")
        candidate = root / path
        if not candidate.is_file() or candidate.is_symlink():
            errors.append(f"{path}: missing or not a regular file")
        elif not os.access(candidate, os.X_OK):
            errors.append(f"{path}: checkout is not executable")
    return errors


def main():
    errors = check(ROOT)
    if errors:
        print("\n".join(errors), file=sys.stderr)
        return 1
    print(f"Verified {len(ENTRYPOINTS)} tracked executable entrypoints.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
