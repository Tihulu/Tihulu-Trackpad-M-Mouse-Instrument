# Logic Pro percussion and Magic Mouse routing

NoSpeaker Studio uses the NoSpeaker Touch MIDI Out CoreMIDI virtual source.
Touch Instrument can now assign an **instrument and destination independently**
to the Force Touch trackpad and the Magic Mouse.

## Example: trackpad drums + Magic Mouse keyboard

1. Open **Touch Instrument**, choose **Active Surfaces → Both**.
2. Set **Force Touch Trackpad → Instrument: Drums**, **Output: MIDI Instrument**.
3. Set **Magic Mouse → Instrument: Melodic**, **Output: MIDI Instrument**
   (or **Both** to also drive the Mac's Force Touch haptic motor).
4. Choose **GM Drum Pads: 8 / 12 / 16 Pads** and a melodic scale/root.
5. In Logic, create a drum-instrument track and a separate software-instrument
   track. Use **NoSpeaker Touch MIDI Out** as the MIDI input source.
6. Route/listen to **MIDI Channel 10** for drums and select another MIDI
   channel for the melodic instrument (default Channel 1), or configure
   appropriate per-track MIDI channel filters.
7. Press **Start Touch Instrument**. Finger markers are visible even before Start,
   but no MIDI/haptic output is emitted until Start.

**Important:** MIDI Channel 10 and a GM percussion note map are not sufficient
to make an arbitrary Logic software-instrument track play drum sounds. You must
load a drum sampler/kit (e.g. one that understands General MIDI percussion)
and ensure its note assignments match the map. Logic Drum Machine Designer
patches can use different note/pad assignments. If they do, choose a matching
kit or edit the Logic pad mapping.

## General MIDI drum mapping

The default **12 Pads** layout uses these left-to-right horizontal zones:

| Pad | MIDI note | GM voice |
|---:|---:|---|
| 1 | 36 | Kick |
| 2 | 38 | Snare |
| 3 | 42 | Closed hi-hat |
| 4 | 46 | Open hi-hat |
| 5 | 39 | Hand clap |
| 6 | 37 | Side stick |
| 7 | 45 | Low tom |
| 8 | 47 | Mid tom |
| 9 | 50 | High tom |
| 10 | 49 | Crash |
| 11 | 51 | Ride |
| 12 | 56 | Cowbell |

The **8 Pads** layout uses the first eight; **16 Pads** adds acoustic bass
drum (35), electric snare (40), pedal hi-hat (44), and tambourine (54).

- Drums always transmit on **MIDI Channel 10** (zero-based channel 9).
- Melodic Standard MIDI uses the chosen channel; if a drum surface is active,
  selecting Channel 10 for melody is automatically rerouted to Channel 1.
- Melodic MPE allocates per-finger member channels and reserves Channel 10
  for percussion, so percussion and melodic fingers can play together.
- Drum touches send **note-on when a pad is touched** and note-off on
  release or when moving out of the pad. Lift and touch again to retrigger.
- Velocity can be fixed or derived from contact size. A physical click is
  **not** required when Trigger is set to **Touch**.

## Magic Mouse can drive either target

- **Trackpad Haptic:** Magic Mouse finger positions play the Mac's Force Touch
  haptic motor. Magic Mouse itself is not the haptic output device.
- **MIDI Instrument:** Magic Mouse finger positions send notes to Logic or
  another MIDI-capable DAW.
- **Both:** Send the same Magic Mouse notes to the DAW and Force Touch motor.
- **Active Surfaces → Both:** Trackpad and Magic Mouse can have different
  instrument mappings and different output destinations.

The separate **MIDI Helper** view remains available for touch-based vibrato,
pitch bend, and expression while another controller plays notes.

## Safety and hardware acceptance

The haptic driver still clamps output strength, frequencies, tone count, and
frame length. NoSpeaker uses private macOS MultitouchSupport APIs. A successful
CI build cannot prove that a particular Magic Mouse generation provides usable
multi-touch frames on that macOS version.

Before calling the feature hardware-ready, verify all of these on a physical Mac:

1. Trackpad drum preview maps X positions to GM pad labels.
2. Logic receives Kick 36 and Snare 38 on MIDI Channel 10, and the loaded
   drum kit produces the expected drum samples.
3. Magic Mouse preview detects one finger and two fingers (if supported),
   with distinct positions, while Trackpad → Drums is running.
4. Magic Mouse → Trackpad Haptic makes the **trackpad** vibrate.
5. Magic Mouse → MIDI Instrument produces melodic note-on/note-off;
   select **Both** and verify both destinations.
6. In Both mode, independent simultaneous drum + melodic notes produce
   no stuck MIDI notes after release and Panic Stop.

Treat this as developer functionality until the physical checks pass.

## MIDI Helper Sustain (CC64)

The MIDI Helper has independent **OFF-by-default** sustain switches for both
input surfaces. Sustain is available regardless of whether Vibrato, Pitch Bend,
Expression or Hybrid mode is selected.

- **Trackpad Contact Sustain:** uses the contact-size signal as an approximation
  of pressure (the private touch callback does **not** provide calibrated Force
  Touch force). Cross an adjustable threshold to send `CC64 = 127`. The
  release threshold is slightly lower to avoid chattering near the cutoff.
  Release or lighten contact below the threshold to send `CC64 = 0`.
- **Magic Mouse Touch Sustain:** no pressure is assumed. Enable its own switch
  and choose **Touch Hold** (sustain on while any finger touches the mouse)
  or **Tap Toggle** (a fresh touch session alternates sustain ON/OFF).
- **Both:** either surface may keep CC64 active. Releasing one surface does not
  turn it off while the other still holds/latches sustain.
- **Routing:** enable **Send Helper to DAW**, and set **Target Channel** to the
  instrument's MIDI channel in Logic. The Helper sends CC64 on its virtual
  `NoSpeaker Touch MIDI Out` source, not on the separate keyboard device.
- **Safety:** selecting another helper channel/surface/sustain mode resets the
  previous latch, and Stop MIDI Helper, Stop MIDI Bridge, and Panic Stop emit
  a release on the old channel. The feature does not modify external hardware
  keyboard pedal state.

The UI shows the combined `CC64 ON / OFF` status. A Logic instrument must
respond to MIDI sustain pedal CC64 for the note-hold behavior to be audible.

## Expressive Controls v2 — Sustain, Gesture Selection and Mouse Capture

The **MIDI Helper** no longer forces an exclusive Vibrato, Bend, Expression
or Hybrid mode. Four independent checkboxes now allow any combination:

- **Vibrato (CC1)** — vertical movement
- **Pitch Bend** — horizontal movement
- **Expression (CC11)** — contact-size estimate
- **Sustain (CC64)** — the separately chosen Trackpad/Mouse gesture

For example, **only Sustain** checked emits no vibrato, bend or expression.
Checking all four produces a Hybrid-like combination. All are OFF by
default except Vibrato, to preserve a useful starting configuration.

### Trackpad and Magic Mouse Sustain

Both MIDI Helper and Touch Instrument have separately enabled sustain
controls. Available Trackpad gestures are: **Touch Hold**, **Tap Toggle**,
**Click Hold**, **Click Toggle**, and **Contact Threshold**.
Magic Mouse gestures are Touch Hold, Tap Toggle, Click Hold and Click
Toggle. Magic Mouse has **no Force Touch sensor**.

For Contact Threshold, the sensor selector offers:
- **Contact Size (default)** from the private touch frame; this is not
  calibrated physical force.
- **Click Pressure (Experimental)** from CoreGraphics mouse-button
  pressure. It requires an actual physical click and may not be
  continuously available or distinguish Force Touch strength on a given
  system. If no click-pressure reading is available, the sustain trigger
  remains OFF instead of falling back to contact size.

Click gestures require **Enable Input Controls** and macOS Accessibility
permission. Because macOS generic click events are not reliably tagged
with which pointing device originated them, NoSpeaker attributes a click
only when exactly one surface has live contact, or one surface is chosen.
If both are concurrently touched, ambiguous clicks are ignored instead
of applying CC64 to the wrong instrument.

### Keyboard Capture and Emergency Exit

Default mode is **OFF** — the mouse operates the desktop normally.

1. Select a capture hotkey: **Control + Option + F6/F7/F8/F9** (F8 by
   default). Some keyboards also require the Fn key for function keys.
2. Choose **Enable Input Controls**. If the OS denies Accessibility,
   the event tap is not installed; allow Studio in System Settings →
   Privacy & Security → Accessibility, then retry.
3. Press the shortcut or turn **Capture Mouse for NoSpeaker** ON.
   While captured, mouse motion, drag, buttons and scrolling are
   suppressed from normal desktop apps. The touch frame receiver still
   drives NoSpeaker. **This is a session-wide pointer capture**, not
   reliable per-device suppression; the trackpad pointer may be affected.
4. Press the shortcut again to return to desktop use. Press **Esc**
   while input controls are armed for **Panic Stop**: disable capture,
   release CC64 and MIDI notes, close haptics and stop ongoing playback.
   With input controls disabled, Esc remains the app-focused panic shortcut.

Capture never starts automatically, does not run as a background daemon,
and is removed on process exit or crash. A macOS event-tap disable event
also triggers panic/uncapture rather than silently keeping control.

### Touch Instrument sustain scope

Touch Instrument sends sustain **MIDI CC64** for melodic DAW instruments
on the relevant MIDI channels, including MPE member channels. GM drum
Channel 10 is excluded. The current Force Touch local haptic engine
still follows physical finger frames and is not a sampled/instrument
voice engine with independent acoustic release tails. Sustain does not
turn a hardware haptic motor into a conventional keyboard sustain pedal.

### Hardware acceptance checklist

These changes compile and have pure logic tests, but require physical Mac
tests before describing the feature as hardware validated:
- Test Trackpad Touch Hold, Tap Toggle, Click Hold, Click Toggle.
- Compare Contact Size and experimental Click Pressure sensors, recording
  whether meaningful nonzero click pressure is available.
- Test Magic Mouse Touch Hold, Tap Toggle, Click Hold, Click Toggle.
- With both surfaces enabled, verify CC64 does not release early.
- In Logic, verify **Sustain only** emits CC64 with no unrelated CC1,
  pitch-bend or CC11 traffic.
- Arm capture, verify assigned hotkey freezes/releases desktop pointer,
  and Escape always restores the pointer and silences MIDI/haptics.
- Verify complete recovery after killing the app while capture is active.

**Do not mark Magic Mouse, Force Touch pressure, or global input capture
as hardware PASS based on GitHub CI alone.**
