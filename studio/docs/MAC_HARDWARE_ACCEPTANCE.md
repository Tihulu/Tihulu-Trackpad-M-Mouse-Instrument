# Mac Hardware Acceptance Checklist

A release must not claim hardware validation until this checklist is executed on a real compatible Mac.

## Environment

Record:

- Mac model
- Apple Silicon or Intel
- macOS version
- Built-in trackpad or external Magic Trackpad
- Commit SHA

## Gate A — Build and launch

```sh
./scripts/verify.sh
./scripts/build-app.sh
open "dist/NoSpeaker Studio.app"
```

Expected: the app opens, attribution is visible, and the status bar reports a compatible Force Touch trackpad.

## Gate B — Safety and diagnostics

1. Set Master to 25%.
2. Play a 1 kHz test tone.
3. Run the 100 Hz → 4 kHz sweep.
4. Press **PANIC STOP** during playback.
5. Confirm output stops and only returns after **Reconnect**.

## Gate C — Voice

1. Open **Voice**.
2. Enter a short sentence.
3. Test System Default plus one installed macOS voice.
4. Confirm the Mac's ordinary speakers are not required for haptic output.

## Gate D — Touch Instrument

1. Start Touch Instrument.
2. Slide left/right and confirm pitch changes.
3. Move vertically and confirm modulation changes.
4. Stop the mode and confirm touching no longer triggers Studio output.

## Gate E — Sequencers

Test Note Sequencer and Drum Sequencer at 90, 120 and 160 BPM. Confirm loop can be stopped immediately.

## Gate F — MIDI / Logic Pro

1. Enable MIDI Bridge.
2. Confirm `NoSpeaker Haptic MIDI` appears in Logic Pro.
3. Send melodic notes.
4. Send drums on channel 10.
5. Load a `.mid` file in Studio.

## Gate G — Audio File

Drop a short WAV and MP3. Test all four conversion profiles.

## Gate H — System Audio Speaker

1. Start system-audio capture.
2. Grant Screen Recording permission if macOS asks.
3. Play local media.
4. Confirm Studio's own process audio is excluded from capture.
5. Stop capture and confirm no further haptic audio is emitted.

## Release decision

Record PASS/FAIL for every gate. Any private-framework crash, inability to panic-stop, or level-control regression blocks release.
