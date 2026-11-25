# DAW multi-instrument routing — Logic Pro

User acceptance example: play flute from Trackpad, Erhu from Touch Bar, drum set from Xbox controller, Hammond organ from Magic Mouse, at the same time. Every physical source should support editable assignments, fast playing and independent release. Do not confuse a MIDI channel with a selected software-instrument sound.

## Standard MIDI candidate

| Source | MIDI Input port in Logic | MIDI In Channel | Software instrument |
|---|---|---:|---|
| Trackpad | NoSpeaker Touch MIDI Out | 1 | Flute |
| Touch Bar (MIDI-only legacy path) | NoSpeaker Touch MIDI Out | 2 | Erhu |
| Magic Mouse | NoSpeaker Touch MIDI Out | 3 | Hammond |
| Xbox 1 (native Builder) | TIHULU Instrument Builder | 10 | Drum kit |

Set both touch surfaces to MIDI Instrument and choose Standard, Fretted, separate channels in Touch Instrument. Trackpad channel 1 and Magic Mouse channel 3 are illustrative, not hardcoded. In Touch Bar choose MIDI-only, piano/keys mapping and channel 2. Use the native Builder controller drum role on channel 10 and explicitly send MIDI. Logic creates four Software Instrument tracks, with each instrument/plug-in chosen by the musician. In each Track Inspector choose MIDI Input (older versions: MIDI In Port) and MIDI In Channel matching the source. Record-enable all four tracks; first play each alone to confirm isolation, then together. Record if desired. Avoid All Inputs/All Channels for independent parts. Apple guide: https://support.apple.com/guide/logicpro/record-multiple-midi-devices-tracks-lgcp8a4693ee/mac

Do not route the outgoing TIHULU ports back into NoSpeaker Haptic MIDI In unintentionally. Verify actual endpoint names in Logic after explicit starts. A channel 10 instrument must still be configured to receive the actual drum note map.

## Code slice

Optional, backwards-compatible workspace setting enables dual standard pitched surface channels. A validated frozen channel pair rejects duplicates and invalid channels. Both selected surfaces must send pitched MIDI and meet existing Standard MIDI restrictions. Notes, chord destinations, bend/expression ownership use their assigned channel; shared Touch sustain deliberately affects both channels, including pre-note sustain. The single automatic Helper target shortcut is unavailable in split mode; explicit target selection remains. Existing shared channel, MPE, GM drum and haptic paths remain defaults. Invalid split configuration blocks Start; not a silent fallback.

Builder's DAW routing overview shows logical channels, note sources and control sources; intentional control-only sharing is distinguished from multiple note producers on one channel. Copyable summary is not a Logic project or an automatic connection. Split controller haptic-only routes are logical, not necessarily sent to MIDI. Tuned Air uses another port and MPE wire channels differ from logical routes.

## Remaining design and acceptance

No physical or Logic playback verification claimed. This candidate does not provide independent MPE zones/virtual ports per touch surface, independent sustain per surface, distinct scales/roots per melodic surface, all-device haptic mixing or automated DAW setup. Keep those separate design gates. MPE must be isolated from ordinary MIDI instruments sharing the same physical port; do not allow overlapping member channels by default. Touch Bar MIDI-only can share the legacy port on an independent channel; its optional Both/haptic path has its own motor ownership restrictions. Validate actual concurrent modes rather than assume support.

Required tests: three authored scenarios cover channel pair validation, logical note/helper overview, and native configuration eligibility. Full CI plus physical test of four independent instruments, each alone and together, including same-note overlap, bend/CC/sustain targeting, fast multi-touch and rapid Xbox hits, stopping one source and scoped cleanup, no ghost notes, no DAW audio dropout, stable reinstall/rollback. A green CI is not physical acceptance.

## Progress reporting contract

Keep overall expanded scope and active-work progress separate from actual test status. Report previous/current/remaining estimates and percentage-point differences every development response. Do not inflate progress from commit count or reclassify pending physical tests as passing. Prior expanded scope estimate 67%; previous active performance work 70%. Track DAW multi-instrument routing as a distinct item. Stable remains untouched.
