"""Black-box smoke tests of the built offline engine executable."""
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import uuid


def run(binary, *args, success=True):
    result = subprocess.run([binary, *map(str, args)], capture_output=True, text=True, timeout=20)
    if success:
        assert result.returncode == 0, result.stderr
        return json.loads(result.stdout)
    assert result.returncode != 0 and not result.stdout, result.stdout
    return result.stderr


def main(binary):
    with tempfile.TemporaryDirectory() as directory:
        root = Path(directory)
        patch, groups, frames = (root / name for name in ("patch.json", "groups.json", "frames.json"))
        caps = run(binary, "capabilities")
        assert caps["hardware"] is False and caps["schema"] == 1
        patch.write_text(json.dumps(run(binary, "patch", "example")))
        assert run(binary, "patch", "validate", patch)["valid"] is True
        assert run(binary, "patch", "routes", patch)["logicalOnly"] is True
        profile = run(binary, "groups", "example")
        groups.write_text(json.dumps(profile))
        assert run(binary, "groups", "validate", groups)["groups"] == 1
        ports = run(binary, "groups", "ports", groups)
        assert ports["registered"] is False and len(ports["ports"]) == 1
        samples = [{"source":"trackpad","sequence":1,"time":1,"values":{"contact":1}},
                   {"source":"trackpad","sequence":2,"time":1.1,"values":{},"releasing":["contact"]}]
        frames.write_text(json.dumps(samples))
        result = run(binary, "groups", "simulate", groups, frames)
        assert result["simulated"] and result["cleanupComplete"] and not result["hardware"]
        assert [e["value"] for e in result["events"]] == [100, 0]
        assert all(e["kind"] == "note" and e["channel"] == 1 for e in result["events"])
        # Panic emits the held note-off even if the trace ends while pressed.
        frames.write_text(json.dumps(samples[:1]))
        result = run(binary, "groups", "simulate", groups, frames)
        assert [e["value"] for e in result["events"]] == [100, 0]
        # Two copies may layer only after explicit consent.
        original = profile["payload"]["groups"][0]
        profile["payload"]["groups"].append({**original, "id": str(uuid.uuid4())})
        groups.write_text(json.dumps(profile))
        run(binary, "groups", "simulate", groups, frames, success=False)
        layered = run(binary, "groups", "simulate", groups, frames, "--allow-layering")
        assert len(layered["events"]) == 4 and len({e["groupID"] for e in layered["events"]}) == 2
        frames.write_text(json.dumps([samples[0], samples[0]]))
        run(binary, "groups", "simulate", groups, frames, "--allow-layering", success=False)
        frames.write_text(json.dumps([{**samples[0], "values":{"contact":2}}]))
        run(binary, "groups", "simulate", groups, frames, "--allow-layering", success=False)
        run(binary, "live", "start", success=False)
    print("Engine CLI smoke tests passed.")


if __name__ == "__main__":
    main(sys.argv[1])
