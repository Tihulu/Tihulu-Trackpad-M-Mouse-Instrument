"""Black-box native CLI boundary: no live sends or permission requests."""
import json
import platform
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
assert set(help_doc["commands"]) == {"capabilities", "preflight", "midi endpoints [--names]", "gamepad devices [--names]", "midi monitor NAME SECONDS --confirm"}
for command in [("start",), ("midi", "send"), ("preflight", "--request-permissions"),
                ("midi", "endpoints", "--names", "--send"), ("--unknown",),
                ("midi", "monitor", "test", "1"), ("midi", "monitor", "test", "0", "--confirm"),
                ("midi", "monitor", "test", "11", "--confirm"), ("midi", "monitor", "test", "01", "--confirm"),
                ("midi", "monitor", "test", "1", "--confirm", "--names"), ("preflight", "--names"), ("gamepad", "devices", "--bind"), ("gamepad", "devices", "--names", "--names")]:
    invoke(*command, success=False)

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
else:
    for command in [("preflight",), ("midi", "endpoints"), ("midi", "endpoints", "--names"),
                    ("gamepad", "devices"), ("gamepad", "devices", "--names"),
                    ("midi", "monitor", "test", "1", "--confirm")]:
        assert "requires macOS" in invoke(*command, success=False)

print("Native CLI capability, read-only boundary and platform tests passed.")
