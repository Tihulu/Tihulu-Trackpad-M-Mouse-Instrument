# Expressive controls: Touch Instrument, MIDI Helper and cursor capture

This document describes the optional experimental controls for NoSpeaker Studio.
The original Voice, Touch Instrument, MIDI / Logic and NoSpeaker haptic motor
paths remain available.

## Touch Instrument Sustain

- **Enable Sustain** defaults to OFF.
- Select **Trackpad Sustain** and/or **Magic Mouse Sustain** separately.
- Trackpad trigger choices:
  - **Contact Threshold**: normalized touch contact size exceeds a threshold.
    Release has hysteresis to avoid rapid CC64 flapping.
  - **Touch Hold**: sustain while any finger is touching the trackpad.
  - **Tap Toggle**: each new touch session toggles sustain ON/OFF.
  - **Physical Click Hold**: a mouse-down attributed to this surface holds sustain.
  - **Physical Click Toggle**: a new click toggles sustain.
- Magic Mouse trigger choices: Touch Hold, Tap Toggle, Physical Click Hold,
  Physical Click Toggle. No pressure sensor is presumed.
- Local Force Touch haptic tones keep refreshing when sustain is enabled, even
  after a finger lifts, until sustain releases or Stop/Panic is used.
- When MIDI output is enabled, sustain emits MIDI CC64 on the Touch
  Instrument's active MIDI channel(s), including MPE member channels.
- Sustain is reset when leaving the Touch Instrument screen, stopping the
  instrument or invoking Panic Stop.

## MIDI Helper expression mapping

- Independent checkboxes select **Vibrato (CC1)**, **Pitch Bend** and
  **Expression (CC11)**. No single mutually exclusive mode is required.
- **Hybrid Preset** checks those three controls; the user may then customize
  any subset.
- **Sustain (CC64)** has its own master checkbox and per-surface switches.
- The Helper's Target Channel must match the Logic instrument you want to
  control. MIDI is transmitted via NoSpeaker Touch MIDI Out.
- All controls can be deactivated without affecting incoming external MIDI
  keyboard notes. Disabling a control resets its last transmitted MIDI state.

## Physical clicking and sensor limitations

- The private multitouch frame contains a **contact-size estimate** in
  the field currently exposed by NoSpeaker. It is not a verified Force
  Touch force measurement. The slider controls normalized contact size,
  not Newtons, pressure in kPa or macOS's calibrated pressure sensor.
- True Force Touch pressure is not implemented for background Logic sessions.
  No claim about accurate pressure/force support is made.
- A macOS CGEvent mouse click does not reliably identify whether the click
  originated from a Magic Mouse or trackpad. NoSpeaker attributes a global
  mouse click only when **exactly one surface has an active touch**. When both
  are touched, it deliberately does not attribute the click, avoiding an
  accidental sustain toggle.
- Physical Click Hold/Toggle need an active macOS event monitor and
  **Accessibility** permission, which the user must grant. Touch Hold,
  Tap Toggle and Contact Threshold do not require that global event monitor.

## Performance cursor capture

- **Enable Global Capture Shortcut** defaults to OFF.
- User-selectable key combinations: **Control+Option+M, K, P or T**.
- While Touch Instrument or MIDI Helper is running, press the chosen shortcut
  to send pointer events exclusively to NoSpeaker, and press it again to
  restore normal macOS pointer input.
- Press **Esc** for Panic Stop: terminate active Studio playback, release
  sustain/notes and unlock the cursor. Esc is global only if Accessibility
  event monitoring has been authorized; when not authorized, the existing
  foreground-window Esc keyboard shortcut still works.
- Input capture applies to **all macOS pointer devices** at the CGEvent layer.
  It cannot safely freeze only Magic Mouse while leaving another pointing
  device completely unaffected. Both the app's UI and user docs state this.
- The event monitor is only installed during a running instrument/Helper
  session. Permission failures are **fail-open**: no cursor suppression.
  Event tap timeout or deactivation releases the cursor and triggers
  Panic Stop instead of leaving the system in a captured state.
- Capture is not a security sandbox or way to prevent keyboard input to
  other software. It simply filters pointer events while a local session runs.

## Acceptance tests to run on a physical Mac

1. Verify both panels default to Sustain OFF; preview alone never generates MIDI.
2. Test Trackpad Touch Hold, Tap Toggle, Contact Threshold and click modes.
3. Test Magic Mouse Touch Hold, Tap Toggle and click modes. Verify two fingers
   do not trigger duplicate toggles in one touch session.
4. Select Both and verify releasing one surface does not prematurely
   release MIDI CC64 if the other is still active.
5. In Touch Instrument, check MIDI CC64 ON/OFF in Logic's MIDI monitor and
   verify local haptic notes remain sounding while sustain is latched.
6. In Helper, enable only Vibrato then only Pitch Bend then only Expression,
   then use Hybrid Preset and manually deselect one. Verify output assignments.
7. Grant Accessibility, enable capture, start a performance, press the chosen
   shortcut, and verify cursor motion/clicking is suppressed across macOS.
   Press the same shortcut to restore all normal input.
8. Re-enable capture and press Esc from Logic. Confirm cursor returns,
   all MIDI CC64 values are OFF, no notes remain stuck, and haptic stops.
9. Deny Accessibility or disable event monitoring and confirm pointer
   capture is impossible and input is never trapped.

**CI build PASS is not a substitute for the physical acceptance checklist.**
