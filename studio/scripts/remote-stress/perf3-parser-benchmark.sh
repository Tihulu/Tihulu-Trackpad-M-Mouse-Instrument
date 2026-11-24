#!/bin/sh
# Run from repository root, with the exact candidate object available.
set -eu
src="$(mktemp -d)"
trap 'rm -rf "$src"' EXIT HUP INT TERM
git show 74818cb142801011250c8707f11af43b13f3f549:studio/Sources/NoSpeakerCore/RemoteFlatJSON.swift > "$src/RemoteFlatJSON.swift"
test "$(git hash-object "$src/RemoteFlatJSON.swift")" = 048a5306098feb5893b02df7ff8177f8dfba088d
cp studio/scripts/remote-stress/perf3-parser-benchmark.swift "$src/main.swift"
python3 - "$src" <<'PY'
import sys
from pathlib import Path
d=Path(sys.argv[1])
p=(d/'RemoteFlatJSON.swift').read_text()
a=p.index('        let string =')
b=p.index('        let input =')
block=p[a:b]
assert p.count(block)==1
out=p.replace('enum RemoteFlatJSON {','enum CachedRemoteFlatJSON {\n    private static let patterns: (NSRegularExpression, NSRegularExpression, NSRegularExpression, NSRegularExpression)? = {\n'+block+'        return (member, start, end, comma)\n    }()').replace(block+'        let input =','        guard let (member, start, end, comma) = patterns else { return nil }\n        let input =')
(d/'CachedRemoteFlatJSON.swift').write_text(out)
PY
swift --version >&2
swiftc -O "$src/RemoteFlatJSON.swift" "$src/CachedRemoteFlatJSON.swift" "$src/main.swift" -o "$src/bench"
"$src/bench"
