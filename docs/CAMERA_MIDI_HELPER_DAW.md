# Camera MIDI Helper — DAW setup and acceptance

Status: experimental development candidate; physical acceptance pending.

## Connect
1. In Instrument Builder add a Camera MIDI Helper assignment or quick setup. Choose left/right hand, motion and MIDI channel (UI 1–16).
2. Add Trackpad/Magic Mouse/other compatible native routes to the same patch if wanted. The camera helper mode cannot yet mix with chord/strum camera modes in one patch.
3. Start Native Inputs explicitly; grant camera access and start again when requested. Enable the dedicated MIDI output deliberately.
4. In the DAW select the TIHULU Instrument Builder MIDI source and the corresponding MIDI channel. Enable input monitoring for an instrument track. For effects use the receiving instrument's CC mapping or MIDI Learn where supported. Do not enable a MIDI feedback loop.
5. Stop the Builder before editing assignments. Use Stop / Release All or DAW panic if delivery fails.

## Example mappings
- Left X → pitch bend, right aperture → CC74 filter/wah.
- Left Y → CC11 expression, right Y → CC1 modulation.
- Left pinch hold → sustain CC64, right pinch toggle → sostenuto CC66.
- Motion speed can control modulation/vibrato depth; CC76 rate and CC77 depth require receiver support. These are MIDI values, not an internal oscillator or audio effect.

Pitch excursion is symmetric about center; the receiver sets the actual semitone range. Example: 50% excursion on an instrument configured for ±2 semitones gives approximately ±1 semitone. No RPN messages are sent. Custom CCs exclude reserved channel controls.

## Safety and physical acceptance
- Open before pinching. Toggle clears on loss; reconnecting with an already closed hand must not re-enable it.
- Test one hand disappearing while the other remains active. Then test both disappearing and disconnecting camera permission.
- Test both hands assigned to the same switch CC, then hand ownership transfer in a single frame.
- Test shared sustain with Trackpad. Confirm its notes remain sounding when the camera releases.
- Check neutral pitch, CC11/7 and switch-off after Stop, timeout and DAW disconnect. Verify receiver behavior using a MIDI monitor.
- Repeat at 15 Hz native capture and synthetic 30 Hz debug, with MIDI output off first.
- Logic Pro, Ableton Live and other DAW compatibility requires actual receiving-application tests. CI does not constitute physical acceptance.
