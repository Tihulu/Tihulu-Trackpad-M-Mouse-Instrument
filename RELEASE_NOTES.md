# Tihulu Trackpad & M. Mouse Instrument v0.2.2

This version adds **read-only global performance capture diagnostics** so permission, event tap, recorded shortcut and pointer capture problems can be distinguished using concrete counters.

## What's new
- **Diagnostics → Global Capture** now displays Accessibility trust and Input Monitoring preflight, event tap creation and enabled state, monitor status, capture-armed state, current pointer capture state, and the recorded shortcut.
- Privacy-safe cumulative counters for global key-down events, pointer events, successful shortcut matches, event tap timeouts and system/user-disabled taps.
- An in-app **Refresh Snapshot** button and **Copy Report** button with actionable next checks; capturing the report never enables input monitoring or requests additional permissions.
- Clear instructions to test the recorded shortcut twice while another application is in focus, then inspect counter changes.
- Additional macOS unit tests verify that diagnostic snapshots do not start an event tap or collect keystrokes.
- Includes v0.2.1 safety fixes: event monitor interruptions no longer stop the haptic motor; captured Escape remains an emergency release; global capture key combination recording retains its enabled state.

## Privacy
No keystrokes, entered text, system-wide key sequences, private audio, hardware IDs or local paths are logged. Only counters and the deliberately recorded performance shortcut are included in a report. Diagnostics are local and require explicit user action to copy.

## Install
Download **Tihulu-Trackpad-M-Mouse-Instrument-macOS.dmg**, verify the checksum against **SHA256SUMS**, and drag the app to Applications. Or use the one-line installer in the README.

The application is an **ad-hoc-signed, not Apple-notarized development build**. macOS Accessibility and Input Monitoring permissions may need to be reapproved after a signature-changing update. The tool relies on private MultitouchSupport APIs and still needs hands-on hardware acceptance. A passing CI build does not establish full hardware compatibility.

Original project: MIT-licensed [os6/nospeaker](https://github.com/os6/nospeaker) by Cody Collier.
