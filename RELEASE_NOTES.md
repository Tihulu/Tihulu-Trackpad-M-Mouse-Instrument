# Tihulu Trackpad & M. Mouse Instrument v0.2.0

The first DMG release under the TIHULU application name, distributed from the new repository.

## Highlights
- Approved TIHULU vector mascot logo, a rendered macOS Dock icon and the complete **Tihulu Trackpad & M. Mouse Instrument** app display name.
- Local English, Turkish and German Voice mode. Voice discovery now includes additional installed Apple AVSpeech enhanced/premium voices, when available on the user's Mac.
- Fretted and Fretless Touch Instrument with the same adjustable size range (**0.50× to 2.00×**).
- Real-time Trackpad and Magic Mouse finger preview, separately routed melodic/GM drum MIDI output and optional trackpad haptics.
- MIDI Helper with independent Vibrato, Pitch Bend, Expression and Sustain (CC64), on/off per surface, selectable Touch/Click Hold/Toggle and experimental click-pressure selection.
- Logic Pro virtual instrument control, MPE per-finger pitch bend, Channel 10 GM drums and active MIDI keyboard support (held-note/sustain/mod wheel/expression).
- User-recorded **global performance capture shortcut** that applies in all Studio modes, with keyboard-combination recording and Escape Panic Stop.

## Install
Download **Tihulu-Trackpad-M-Mouse-Instrument-macOS.dmg**, mount it and drag the app into Applications. Alternatively use the one-line installer from the repository README. SHA-256 checksums are published.

## Signing and safety
**This DMG is a developer build signed ad-hoc, not Apple Developer ID notarized.** It is not a verified commercial installer. Depending on macOS Gatekeeper, you may be prompted to review the application before opening. Grant Accessibility/Input Monitoring for global capture only if you trust this build. Screen Recording is separately required for system audio capture. The global capture toggle is OFF by default; Esc provides a panic stop.

Private macOS MultitouchSupport APIs, Magic Mouse touch enumeration, pitch/pressure readings, and real hardware Logic performance require hands-on tests. Passing CI validates the build and automated tests, **not hardware acceptance**.

Based on MIT-licensed [os6/nospeaker](https://github.com/os6/nospeaker) by Cody Collier. Upstream project and authorship remain credited.
