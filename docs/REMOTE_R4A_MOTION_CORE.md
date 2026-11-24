# Remote R4a — motion normalization foundation

This increment adds pure Swift helpers and deterministic tests only. It does not enable any new Remote wire messages, device permissions, UI, or MIDI routes. R3b touch behavior is unchanged. No motion hardware acceptance is claimed.

- Orientation: relative browser alpha/beta/gamma in degrees, neutral calibration, configurable 5–90 degree half-sweep, shortest-path yaw/pitch wrapping, bounded normalized outputs. These are local Euler controls, not a fused 3D orientation or reliable compass. Near Euler singularities and large rotations the next adapter must reject/recalibrate rather than promise smooth tracking.
- Motion: gravity-free acceleration in m/s², rotation rate in deg/s, magnitudes normalized independently. Missing or non-finite data is unavailable; never synthesize gravity-free acceleration. Saturation and outlier limits are host defaults, not client-controlled MIDI values.
- Freshness: independent host-receipt gates per stream, explicit arm/disarm, 350 ms watchdog, no replay or gap resurrection. The future adapter must call expire even when no messages arrive and release only the corresponding owned controls. This code does not itself release MIDI.

## Next gates
1. Extend versioned authenticated protocol with strict schema, complete bounded snapshots, per-stream sequence/receipt policy and explicit release. Keep v1 clients compatible; avoid a shared heartbeat that masks stale axes.
2. Wire normalized motion signals into Instrument Builder with independently owned continuous routes, no implicit Note On or sustain; host-side calibration, safe pitch-bend center and configurable CC release.
3. Add explicit browser permission/user gesture and feature detection, secure context, visible armed state, local sample coalescing, bounded rate, and release on background, permission loss, disconnect or stop. Screen rotation must require recalibration. No sensor transmission by default.
4. Reproduce macOS and Linux tests; real iOS/Android permission, sensor availability, screen rotation, TLS, latency and DAW acceptance remain separate HOLD items.

Run from studio: swift test --filter remoteMotion; swift test --filter remoteTilt; then full existing CI.
