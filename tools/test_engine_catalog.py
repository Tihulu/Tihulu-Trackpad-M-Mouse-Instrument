"""Check the published machine-readable feature map against built CLI help."""
import json
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
NAME = "tihulu-mac-instrument-engine"


def main(binary):
    catalog = json.loads((ROOT / "docs/ENGINE_CAPABILITIES.json").read_text())
    assert catalog["schema"] == 1 and catalog["status"] == "experimental"
    names = [p["name"] for p in catalog["products"]]
    assert NAME in names and "tihulu-engine" not in names
    assert len(names) == len(set(names))
    features = catalog["features"]
    assert len({f["id"] for f in features}) == len(features)
    commands = set()
    for feature in features:
        for source in feature["source"]:
            path = (ROOT / source).resolve()
            assert path.is_relative_to(ROOT) and path.is_file(), source
        if feature["id"] != "source-retrieval":
            assert len(feature["cli"]) == len(set(feature["cli"])), feature["id"]
            commands.update(feature["cli"])
    help_doc = json.loads(subprocess.check_output([binary, "--help"], timeout=20))
    exposed = { " ".join(s.split()[:2]) for s in help_doc["commands"] }
    assert exposed == commands | {"capabilities"}, (exposed, commands)
    index_help = subprocess.check_output(
        [sys.executable, str(ROOT / "tools/repo_index.py"), "--help"],
        text=True, timeout=20)
    retrieval = next(f for f in features if f["id"] == "source-retrieval")
    assert all(cmd in index_help for cmd in retrieval["cli"])
    assert catalog["constraints"]["automaticHardwareActivation"] is False
    print("Engine catalog matches executable command help and source paths.")


if __name__ == "__main__":
    main(sys.argv[1])
