# Tihulu Trackpad & M. Mouse Instrument v0.2.1

A safety and reliability patch for global performance capture, shortcut recording, and unexpected trackpad stops.

## Fixed
- Recover from a transient macOS CGEvent event-tap timeout when the system allows it; immediately release the desktop pointer instead of leaving it captured.
- When macOS disables the input monitor, safely disarm global capture **without** calling hardware Panic Stop or closing the Force Touch motor. Voice, touch instruments, sequencers, MIDI, and audio modes remain available.
- Only treat global Escape as an emergency Panic Stop when the desktop pointer is actually captured. Normal Escape in other apps no longer stops the haptic driver merely because a touch/click monitor is active.
- Retain the existing global-capture enabled/disabled setting when the user records or cancels a shortcut, including key combinations.
- Surface actionable Accessibility and Input Monitoring guidance if a global event tap cannot be created.
- Add macOS regression tests for global Escape safety and exact keyboard modifier matching.

## Still included from v0.2.0
- **Tihulu Trackpad & M. Mouse Instrument** application identity and approved editable SVG icon.
- English interface, with local Turkish/English/German installed macOS voice selection.
- Matching **0.50×–2.00×** touch-size limits in Fretted and Fretless modes.
- Separate trackpad and Magic Mouse melodic/GM drum input, optional motor haptics, Logic Pro MIDI/MPE, note/drum sequencers and optional system audio.

## Install
Download `Tihulu-Trackpad-M-Mouse-Instrument-macOS.dmg`, verify against `SHA256SUMS`, mount, and drag the app into Applications. Alternatively use the one-line installer in README.md. The previous v0.2.0 DMG remains available for rollback.

## Permissions and safety
Global capture is optional and OFF by default. When enabled, macOS may require Accessibility and Input Monitoring access for the **installed application** under System Settings → Privacy & Security. Restart the app after granting permission. The user-recorded shortcut toggles capture in every mode; Escape is reserved as an emergency release while captured. The on-screen PANIC STOP remains available.

**This CI-built DMG is ad-hoc signed, not Developer ID notarized.** Ad-hoc updates can require permission re-approval. The app uses private MultitouchSupport APIs, so a successful macOS build/test does not establish compatibility with every actual trackpad or Magic Mouse. Hardware acceptance remains required before claiming stable public release.

Upstream credit: MIT-licensed [os6/nospeaker](https://github.com/os6/nospeaker) by Cody Collier.
