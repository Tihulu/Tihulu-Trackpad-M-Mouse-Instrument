"""Black-box smoke tests of the built offline engine executable."""
import base64
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
        scale = run(binary, "scale", "plan", "60", "0, 180, 400, 700, 1200")
        assert scale["microtonal"] and scale["planned"]
        assert [p["note"] for p in scale["pitches"]] == [60, 62, 64, 67]
        assert scale["pitches"][1]["bend"] < 8192
        run(binary, "scale", "plan", "60", "0, 150, 400", success=False)
        frames.write_text(json.dumps([
            {"source":"touch","frame":{"tones":[{"frequencyHz":220,"amplitude":1}],
                                       "durationMS":18,"level":0.4}},
            {"source":"gamepad","frame":{"tones":[{"frequencyHz":330,"amplitude":1}],
                                         "durationMS":18,"level":0.4}}
        ]))
        mixed = run(binary, "haptics", "mix", frames)
        assert mixed["hardware"] is False
        assert sorted(t["frequencyHz"] for t in mixed["frame"]["tones"]) == [220, 330]
        assert mixed["frame"]["durationMS"] <= 18
        invalid = json.loads(frames.read_text())
        invalid[1]["source"] = "touch"
        frames.write_text(json.dumps(invalid))
        run(binary, "haptics", "mix", frames, success=False)
        # Use actual Standard MIDI File bytes, not a replacement renderer.
        frames.write_text(json.dumps({"bpm":120,"length":960,"notes":[
            {"start":0,"duration":480,"channel":0,"pitch":60,"velocity":90}]}))
        encoded = run(binary, "midi", "encode", frames)
        midi = base64.b64decode(encoded["data"], validate=True)
        assert midi[:14] == bytes.fromhex("4d 54 68 64 00 00 00 06 00 00 00 01 03 c0")
        assert midi[14:18] == b"MTrk" and len(midi) == encoded["bytes"]
        assert midi.endswith(bytes.fromhex("ff 2f 00"))
        assert bytes.fromhex("90 3c 5a") in midi and bytes.fromhex("80 3c 00") in midi
        assert encoded["nominalPitchesOnly"] and not encoded["hardware"]
        frames.write_text(json.dumps({"bpm":120,"length":960,"notes":[
            {"start":0,"duration":480,"channel":0,"pitch":60,"velocity":90},
            {"start":100,"duration":480,"channel":0,"pitch":60,"velocity":90}]}))
        run(binary, "midi", "encode", frames, success=False)
        frames.write_text(json.dumps({"bpm":120,"length":960,"notes":[
            {"start":0,"duration":480,"channel":0,"pitch":60,"velocity":90,"cents":-20}]}))
        run(binary, "midi", "encode", frames, success=False)
        melody = {"bpm":120,"stepsPerBeat":4,"length":16,"channel":2,
                  "steps":[{"index":0,"midi":60,"velocity":0.8,"gate":0.8},
                           {"index":1,"velocity":0.8,"gate":0.8}]}
        frames.write_text(json.dumps(melody))
        assert run(binary, "midi", "melody", frames)["notes"] == 1
        melody["steps"][1]["index"] = 0
        frames.write_text(json.dumps(melody))
        run(binary, "midi", "melody", frames, success=False)
        frames.write_text(json.dumps({"bpm":120,"stepsPerBeat":4,"length":16,
            "hits":[{"index":0,"voice":"kick","velocity":1},
                    {"index":4,"voice":"snare","velocity":0.8}]}))
        drums = base64.b64decode(run(binary, "midi", "drums", frames)["data"], validate=True)
        assert bytes.fromhex("99 24 7f") in drums and bytes.fromhex("99 26") in drums
        frames.write_text(json.dumps([
            {"owner":"touch","channels":[0]},
            {"owner":"helper","channels":[0,2]},
            {"owner":"touch","channels":[]},
            {"owner":"helper","channels":[]}]))
        pedal = run(binary, "sustain", "simulate", frames)
        assert [(e["step"],e["channel"],e["value"]) for e in pedal["events"]] == [
            (0,1,127),(1,3,127),(3,1,0),(3,3,0)]
        assert all(e["cc"] == 64 for e in pedal["events"])
        frames.write_text(json.dumps([{"owner":"helper","channels":[16]}]))
        run(binary, "sustain", "simulate", frames, success=False)
        target = {"kind":"controlChange","channel":0,"number":7}
        touch = {"target":target,"value":35,"neutral":127}
        helper = {"target":target,"value":48,"neutral":127,"preserveOnRelease":True}
        frames.write_text(json.dumps([
            {"owner":"touch","controls":[touch]},
            {"owner":"helper","controls":[helper]},
            {"owner":"touch","controls":[]},
            {"owner":"helper","controls":[]}]))
        controls = run(binary, "helper", "simulate", frames)["events"]
        assert [(e["step"],e["value"]) for e in controls] == [(0,35),(2,48)]
        assert controls[-1]["preserveOnRelease"] is True
        bend = {"target":{"kind":"pitchBend","channel":2,"number":0},
                "value":9000,"neutral":8192,"bendRange":12}
        frames.write_text(json.dumps([{"owner":"helper","controls":[bend]}]))
        controls = run(binary, "helper", "simulate", frames)["events"]
        assert controls[0]["bendRange"] == 12 and controls[0]["channel"] == 3
        assert controls[-1]["value"] == 8192
        for number in (6, 64, 101, 120):
            invalid = {**touch,"target":{**target,"number":number}}
            frames.write_text(json.dumps([{"owner":"helper","controls":[invalid]}]))
            run(binary, "helper", "simulate", frames, success=False)
        frames.write_text(json.dumps([{"owner":"helper","controls":[touch,touch]}]))
        run(binary, "helper", "simulate", frames, success=False)
        run(binary, "live", "start", success=False)
    print("Engine CLI smoke tests passed.")


if __name__ == "__main__":
    main(sys.argv[1])
