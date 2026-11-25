"""Black-box native CLI boundary: no live sends or permission requests."""
import json
import platform
import selectors
import signal
import time
import subprocess
import sys

binary = sys.argv[1]


def invoke(*args, success=True):
    result = subprocess.run([binary, *args], capture_output=True, text=True, timeout=20)
    if success:
        assert result.returncode == 0, result.stderr
        return json.loads(result.stdout)
    assert result.returncode != 0 and not result.stdout and result.stderr
    return result.stderr


mac = platform.system() == "Darwin"
help_doc = invoke("--help")
assert help_doc == invoke("capabilities") == invoke()
assert help_doc["schema"] == 1
assert help_doc["product"] == "tihulu-mac-instrument-native"
assert help_doc["platformSupported"] == mac
assert help_doc["liveOutput"] is False and help_doc["permissionRequests"] is False
assert set(help_doc["commands"]) == {"capabilities", "preflight", "midi endpoints [--names]", "gamepad devices [--names]", "gamepad sample --confirm", "midi monitor NAME SECONDS --confirm", "session probe SECONDS --confirm", "midi plan JSON", "midi simulate JSON"}
for command in [("start",), ("midi", "send"), ("preflight", "--request-permissions"),
                ("midi", "endpoints", "--names", "--send"), ("--unknown",),
                ("midi", "monitor", "test", "1"), ("midi", "monitor", "test", "0", "--confirm"),
                ("midi", "monitor", "test", "11", "--confirm"), ("midi", "monitor", "test", "01", "--confirm"),
                ("midi", "monitor", "test", "1", "--confirm", "--names"), ("preflight", "--names"), ("gamepad", "devices", "--bind"), ("gamepad", "devices", "--names", "--names"), ("gamepad", "sample"), ("gamepad", "sample", "--confirm", "--names"), ("gamepad", "sample", "--confirm", "--confirm")]:
    invoke(*command, success=False)

for command in [("session", "probe", "1"), ("session", "probe", "0", "--confirm"),
                ("session", "probe", "11", "--confirm"), ("session", "probe", "01", "--confirm"),
                ("session", "probe", "1", "--confirm", "--names")]:
    invoke(*command, success=False)
clip = {"bpm": 120, "length": 1920, "notes": [
    {"start": 0, "duration": 480, "channel": 0, "pitch": 60, "velocity": 90},
    {"start": 240, "duration": 480, "channel": 1, "pitch": 64, "velocity": 80},
    {"start": 480, "duration": 480, "channel": 0, "pitch": 60, "velocity": 90}]}
plan = invoke("midi", "plan", json.dumps(clip))
assert plan["command"] == "midi plan" and plan["liveOutput"] is False
assert plan["result"] == {"noteCount": 3, "eventCount": 6, "durationNS": 1000000000,
                          "peakConcurrentNotes": 2, "hardware": False, "receiverConfirmed": False}
for bad in [dict(clip, length=19201), dict(clip, notes=[]), dict(clip, notes=clip["notes"] * 86),
            dict(clip, notes=[dict(clip["notes"][0], velocity=0)]),
            dict(clip, notes=[dict(clip["notes"][0], destination="external")]),
            dict(clip, notes=[clip["notes"][0]]*2), dict(clip, output="external")]:
    invoke("midi", "plan", json.dumps(bad), success=False)
for bad in ("", "{", "x"*65537, "/tmp/clip.json"):
    invoke("midi", "plan", bad, success=False)
invoke("midi", "plan", json.dumps(clip), "--confirm", success=False)
wire = json.dumps(clip)
for bad in [wire.replace('"bpm": 120', '"bpm": 120, "bpm": 121'),
            wire.replace('"pitch": 60', '"pitch": 60, "pitch": 61', 1),
            wire.replace('"pitch": 60', '"pitch": 60.0', 1),
            wire.replace('"pitch": 60', '"pitch": true', 1),
            wire.replace('"pitch": 60', r'"p\u0069tch": 60', 1),
            wire + " {}"]:
    invoke("midi", "plan", bad, success=False)
simulation = invoke("midi", "simulate", wire)
assert simulation["command"] == "midi simulate" and simulation["liveOutput"] is False
assert simulation["result"] == {"noteOns": 3, "noteOffs": 3, "peakConcurrentNotes": 2,
                                "durationNS": 1000000000, "outstandingNotes": 0,
                                "completed": True, "hardware": False, "receiverConfirmed": False}
for bad in ("", "{}", wire.replace('"pitch": 60', '"pitch": 60, "pitch": 61', 1)):
    invoke("midi", "simulate", bad, success=False)
invoke("midi", "simulate", wire, "--confirm", success=False)
probe = invoke("session", "probe", "1", "--confirm")
assert probe["command"] == "session probe" and probe["liveOutput"] is False
assert probe["result"] == {"requestedSeconds": 1, "completed": True, "hardware": False}

# Actual process signals on both platforms, after explicit readiness.
# Never start a physical device or send MIDI in this test.
for signum in (signal.SIGINT, signal.SIGTERM):
    with subprocess.Popen([binary, "session", "probe", "10", "--confirm"],
                          stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True) as process:
        try:
            with selectors.DefaultSelector() as selector:
                selector.register(process.stderr, selectors.EVENT_READ)
                assert selector.select(timeout=5), "Probe did not become ready"
                assert process.stderr.readline().strip() == "session probe ready"
            started = time.monotonic()
            process.send_signal(signum)
            stdout, stderr = process.communicate(timeout=5)
            assert process.returncode == 2 and not stdout, (process.returncode, stdout, stderr)
            assert stderr.count("session probe cleanup") == 1, stderr
            assert stderr.index("session probe cleanup") < stderr.index("Session cancelled; no success report."), stderr
            assert time.monotonic() - started < 5
        finally:
            if process.poll() is None:
                process.kill()
                process.communicate()

if mac:
    # Unique missing source must fail without attaching any input port.
    import uuid
    missing = invoke("midi", "monitor", "TIHULU-absent-"+str(uuid.uuid4()), "1", "--confirm", success=False)
    assert missing.strip() == "tihulu-mac-instrument-native: Selected MIDI source is unavailable.", missing
    def midi_shape(midi, named):
        for count, names in [("sourceCount", "sourceNames"), ("destinationCount", "destinationNames")]:
            assert type(midi[count]) is int and midi[count] >= 0
            if named:
                assert len(midi[names]) == min(midi[count], 256)
                assert all(isinstance(n, str) and 0 < len(n) <= 128 for n in midi[names])
            else:
                assert names not in midi
        assert type(midi["namesTruncated"]) is bool

    pre = invoke("preflight")
    assert pre["schema"] == 1 and pre["liveOutput"] is False
    assert pre["command"] == "preflight"
    for key in ("accessibilityGranted", "inputMonitoringGranted"):
        assert type(pre["result"][key]) is bool
    assert type(pre["result"]["connectedGamepadCount"]) is int
    midi_shape(pre["result"]["midi"], False)
    midi_shape(invoke("midi", "endpoints")["result"], False)
    # Explicit names flag; never print device names in CI.
    midi_shape(invoke("midi", "endpoints", "--names")["result"], True)
    for named in (False, True):
        args = ("gamepad", "devices", "--names") if named else ("gamepad", "devices")
        report = invoke(*args)
        assert report["command"] == "gamepad devices" and report["liveOutput"] is False
        value = report["result"]
        count = value["connectedCount"]
        assert type(count) is int and 0 <= value["extendedProfileCount"] <= count
        assert value["maximumLogicalSlots"] == 4
        assert len(value["devices"]) == min(16, count)
        assert value["omittedCount"] == max(0, count-16)
        for i, device in enumerate(value["devices"], 1):
            assert device["ordinal"] == i
            assert all(type(device[k]) is bool for k in ("extendedProfile", "leftStickClick", "rightStickClick"))
            assert device["extendedProfile"] or not (device["leftStickClick"] or device["rightStickClick"])
            assert ("name" in device) == named
            if named:
                assert 0 < len(device["name"]) <= 128
    sample = invoke("gamepad", "sample", "--confirm")
    assert sample["command"] == "gamepad sample" and sample["liveOutput"] is False
    value = sample["result"]
    count = value["connectedCount"]
    assert type(count) is int and count >= 0
    assert len(value["devices"]) == min(16, count)
    assert value["omittedCount"] == max(0, count-16)
    for ordinal, device in enumerate(value["devices"], 1):
        assert device["ordinal"] == ordinal
        assert device["status"] in {"sampled", "unsupported", "invalid", "disconnected"}
        assert set(device) == ({"ordinal", "status", "active"} if device["status"] == "sampled" else {"ordinal", "status"})
        if device["status"] == "sampled":
            assert len(device["active"]) <= 18
            assert all(type(v) in (int, float) and 0 <= v <= 1 for v in device["active"].values())
else:
    for command in [("preflight",), ("midi", "endpoints"), ("midi", "endpoints", "--names"),
                    ("gamepad", "devices"), ("gamepad", "devices", "--names"), ("gamepad", "sample", "--confirm"),
                    ("midi", "monitor", "test", "1", "--confirm")]:
        assert "requires macOS" in invoke(*command, success=False)

print("Native CLI capability, read-only boundary and platform tests passed.")
