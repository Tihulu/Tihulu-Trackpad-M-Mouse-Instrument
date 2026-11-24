# Universal Sensor Engine - first increment

This is a hardware-independent core plus a native Mapping Lab simulator. It is not a live sensor migration, Camera or Remote implementation. Existing device paths remain unchanged and are not routed through this core yet.

## Contracts
- Typed source kinds and normalized signals, explicit calibration/range/inversion/endpoint dead zone/response curve.
- Bounded 16 session leases and 64 declarative routes, fresh UUID on reconnect. Host monotonic timestamps, strict per-session sequence, stale/invalid rejection. Adapter must authenticate and translate timestamps; no trust in phone clocks.
- Gate threshold/hysteresis. Shared note and sustain ownership: first owner triggers, final owner releases. Continuous controls: highest priority, stable mapping/session tie break, fall back to remaining owner or defined neutral. Pitch bend is 14-bit; CC64 dedicated, generic channel-mode CCs forbidden.
- Configure only when idle; reject invalid or duplicate mappings atomically. Disconnect, explicit watchdog expiry and Panic return scoped release/reset commands. No MIDI side effects, no auto-start, no raw sensor recording.
- Router is a single-owner value type; caller must serialize operations. A future output adapter must maintain ownership across legacy routes and router routes, handle output delivery failure/reconnect, avoid overlapping notes with external devices, and arbitrate shared haptic resources. Do not attach to the existing CoreMIDI bridge until these integration gates pass.

## UI
Mapping Lab: two simulated input devices, selectable note/CC/bend/sustain routes, common channel, inversion and priority, move sliders, disconnect one and inspect bounded command monitor. Explicitly no real MIDI or sensor permissions. Leaving the lab releases simulation state only. Same-kind sources share source-kind mappings at this stage; per-device selectors are future work. No full project save or patch graph yet.

## Acceptance
Core tests: shared note ownership, sustain/hysteresis, scoped expiry, priority fallback, stale/invalid/reconnect events, route/session limits, invalid configuration. Native Mac visual and interaction check: two note routes, move both above threshold, disconnect A while B remains, then disconnect B; only one Note On and final Note Off. Repeat with shared continuous filter and bend; check fallback to A. Verify no actual MIDI or permissions. Existing legacy hardware routes unaffected.

## Next increments
1. Central output arbitration and CoreMIDI sink with mocked delivery tests, explicit live opt-in, no stuck notes on device loss.
2. First physical adapter (Touch Bar or calibrated lid) and per-device capability/identity mapping, then native Vision hand tracking.
3. Versioned mapping presets, richer rules and patch graph; authenticated local web controller and phone sensors follow after the ownership and watchdog gates.
