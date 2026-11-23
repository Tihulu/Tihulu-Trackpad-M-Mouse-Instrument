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
