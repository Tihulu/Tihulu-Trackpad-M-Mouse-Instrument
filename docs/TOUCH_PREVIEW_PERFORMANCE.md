# Touch Instrument preview performance

Status: isolated candidate, physical performance acceptance pending.

Source findings: each accepted shared surface snapshot previously assigned the published Touch/Helper state regardless of equality or visible preview. Touch also published a primary contact and sustain booleans. SwiftUI animated both coordinates of each contact on every update and applied a shadow. Native note mapping was recalculated per input frame.

Changes: cache note mapping under the existing configuration/revision lock; keep unthrottled live snapshots for musical processing and physical-click sustain handling; cap motion-only preview publication at about 60 Hz while allowing an immediate empty-state clear; avoid equal publications; stop off-page preview updates without stopping live performance; remove contact movement animation/shadow. The cap is not a fixed display refresh rate. Existing main-actor frame dispatch, MIDI ownership, render timer and safety deadlines remain unchanged. No raw note-edge coalescing.

Local isolated Swift check of cadence logic: 14 assertions passed; 1000 synthetic motion updates over one second yielded 59 visual publications. This is not measured native CPU usage, audio latency or a hardware acceptance result.

## Native implementation policy

Prefer Swift for macOS/iOS/iPadOS logic, SwiftUI for ordinary native UI and appropriate AppKit/UIKit/CoreMIDI/Core Bluetooth/Network APIs for low-latency or platform-specific functions. Share pure Swift core code where platform availability permits. Keep audio/MIDI and touch processing independent of UI refresh. Use native Kotlin/Android APIs for Android and standard web APIs for the browser client; do not add another runtime or rewrite working modules merely to use Swift. Cross-platform protocol fixtures remain shared.

## Required acceptance

Compare the same physical Mac and instrument/DAW before/after under fast taps, rolls, multi-finger fretless MPE, Magic Mouse + Trackpad, Helper with shared sustain, preview-only and off-page live playback. Verify note-on/off ordering and no stuck notes, no dropped short taps, immediate lift clearing, unchanged haptic behavior. Record input callback frequency, main queue delay, MIDI dispatch latency, visual frame intervals and CPU. Use signposts/Instrument traces without storing touch coordinates or note content by default.

If lag remains, profile main-actor dispatch and native render/driver time; consider an edge-preserving bounded pipeline with explicit failure cleanup, never silently discard note edges. Do not move musical processing to another queue until ownership, CoreMIDI lifecycle and revision fencing have independent tests.
