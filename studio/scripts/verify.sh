#!/bin/sh
set -eu
cd "$(dirname "$0")/.."

echo "==> Running shared-core tests"
swift test

echo "==> Building available targets"
swift build

echo "==> Testing standalone engine CLI"
python3 ../tools/test_engine_cli.py "$(swift build --show-bin-path)/tihulu-engine"

echo "==> Testing repository index"
python3 ../tools/test_repo_index.py
index_dir="$(mktemp -d)"
trap 'rm -rf "$index_dir"' EXIT HUP INT TERM
python3 ../tools/repo_index.py build --repo .. --ref HEAD --out "$index_dir/repo.json"
python3 ../tools/repo_index.py verify --repo .. --index "$index_dir/repo.json"
python3 ../tools/repo_index.py search --repo .. --index "$index_dir/repo.json" --query "SensorRouter sustain" --limit 3 > "$index_dir/results.json"
python3 - "$index_dir/results.json" <<'PY'
import json, sys
with open(sys.argv[1]) as stream:
    result = json.load(stream)
assert result["mode"] == "lexical" and result["source_verified"] and result["results"]
assert all(row["blob"] and row["start"] > 0 for row in result["results"])
PY

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
