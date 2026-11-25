#!/bin/sh
set -eu
cd "$(dirname "$0")/.."

echo "==> Disk image retry policy tests (no disk image operations)"
sh scripts/test-diskimage-retry.sh

echo "==> Running shared-core tests"
swift test

echo "==> Building available targets"
swift build

echo "==> Parsing macOS-only Swift sources for syntax"
swiftc -frontend -parse Sources/NoSpeakerMac/*.swift Sources/NoSpeakerStudio/*.swift

echo "==> Checking required attribution"
grep -q "Cody Collier" README.md
grep -q "os6/nospeaker" ATTRIBUTION.md
grep -q "MIT" NOTICE

echo "==> Checking repository text for Turkish characters"
python3 - <<'PY'
from pathlib import Path
bad_chars=set('çğıöşüÇĞİÖŞÜ')
roots=[Path('Sources'),Path('Tests'),Path('docs'),Path('README.md'),Path('ATTRIBUTION.md'),Path('NOTICE'),Path('CONTRIBUTING.md')]
found=[]
for root in roots:
    files=[root] if root.is_file() else [p for p in root.rglob('*') if p.is_file()]
    for p in files:
        try: s=p.read_text(encoding='utf-8')
        except UnicodeDecodeError: continue
        for n,line in enumerate(s.splitlines(),1):
            # One explicitly approved Turkish audio string is localized data,
            # not a Turkish UI label, source comment or documentation sentence.
            if (p == Path('Sources/NoSpeakerStudio/StudioController.swift')
                    and line.strip() == 'nonisolated static let startupGreeting = "KOMUTAN LOGAR, BİR CİSİM YAKLAŞIYOR EFENDİM."'):
                continue
            if any(ch in bad_chars for ch in line): found.append((p,n,line))
if found:
    for p,n,line in found: print(f'{p}:{n}:{line}')
    raise SystemExit('Turkish characters found. Project content must remain English.')
PY

echo "Verification passed."
