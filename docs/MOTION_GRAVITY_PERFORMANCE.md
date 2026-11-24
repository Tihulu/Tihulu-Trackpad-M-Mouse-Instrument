# Motion and Gravity — native-input checkpoint

The Builder's expressive preset panel uses actual paired phone/tablet signals: touch X/Y, relative tilt yaw/pitch/roll, acceleration magnitude excluding gravity, and rotation magnitude. Legacy generic angle/speed routes are simulation-only and are not silently migrated. Select Native inputs and the Remote panel; arm supported browser sensors explicitly. Three-axis Tilt Bend + Wah + Expression shares the existing orientation stream, neutral calibration, reservation and 350 ms expiry. No absolute compass heading is implied.

MacBook lid (Gravity/Tilt): calibrated comfortable sweep defaults to 90–120 degrees in the expressive preset panel. The read-only experimental HID adapter is hardware dependent. Do not force the display. The mapping uses the same native scalar runtime, MIDI release behavior and existing route calibration. No new hardware or permissions claim.

Acceptance: test phone/tablet rotation, tilt neutral and loss; confirm simultaneous touch and motion on the paired device; test lid hardware availability and small movements; verify the receiving DAW's assigned CCs and pitch-bend range. CI and physical acceptance remain separate.

## Touch Bar lifecycle
Native pitch bend and fretless controls return to center on release; continuous expression/filter/wah remain latched. Disabling live tilt returns its old target to neutral without starting MIDI. Profile changes stop live tilt before replacing its routing. Unchanged native bar installations reuse the existing controls. When adding/removing the Builder ribbon requires replacing the bar, retire the entire Touch Bar gesture domain first (native and on-screen); other instrument sessions are not stopped. Verify these transitions on real hardware, including held notes, pedal state and the receiving DAW's controller monitor.
