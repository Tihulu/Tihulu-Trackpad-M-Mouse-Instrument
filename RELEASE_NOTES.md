# Tihulu Trackpad & M. Mouse Instrument v0.2.3

A focused **macOS reliability patch** based on a real macOS 26.3.1 diagnostic showing 8 successful global shortcut matches but 22 CGEvent tap timeouts, and a separate CoreMIDI client creation error (OSStatus -2).

## Changes

- **Global Capture:** move the filtering CGEvent tap off SwiftUI's main run loop onto a dedicated user-interactive event thread. Preserve read-only diagnostic counters and explicit fail-open cursor release after a macOS tap disable. This targets main-thread stalls; real-hardware confirmation is still required.
- **CoreMIDI:** keep a single process-lifetime CoreMIDI client instead of disposing the last client during every MIDI mode start/stop. Retain virtual MIDI endpoints across ordinary mode stops, keeping Logic Pro MIDI routes visible. Report actionable OSStatus -2 context.
- **Logo:** render the approved SVG to a macOS .icns icon on every local source build. Install the renderer via Homebrew if available. If icon generation cannot complete, stop the source build instead of silently installing a blank Dock icon.
- **Existing features:** keep Voice (local installed macOS voices), Touch Instrument, MIDI Helper, Magic Mouse and trackpad routing, sequencers, diagnostics and emergency Panic Stop as in v0.2.2.

## What is not claimed

We cannot reproduce the iPhone Continuity Microphone transition or private macOS MultitouchSupport hardware in GitHub Actions. CI build success is not a real-Mac pass for long-running pointer suppression, phone microphone switching, or Logic MIDI persistence.

## Install

Use the DMG from this GitHub Release or the one-line installation documented in README.md. The app is **ad-hoc-signed and not notarized**; Accessibility and Input Monitoring permissions may require review after reinstall. All documentation and interface text is in English.

Original project attribution: MIT-licensed [os6/nospeaker](https://github.com/os6/nospeaker) by Cody Collier.
