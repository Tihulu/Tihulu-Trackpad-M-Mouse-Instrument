# Relative continuous control — candidate contract

Status: source-level implementation and portable tests; not universal live support or Logic feedback acceptance. Absolute remains default. Use the existing response editor for manual relative routes.

- **Absolute:** calibrated position maps directly to the configured output range.
- **Relative:** the first eligible input anchors the origin without writing MIDI. Subsequent signed displacement, gain and optional smoothing produce a bounded wire value from the selected reference. Do not accumulate quantization error or use position mode for note/strike/gate inputs.
- **Manual:** explicitly configured normalized value. It may differ from the actual receiver, so the first movement can still jump.
- **Last delivered:** an adapter's verified successful local send for the same endpoint/channel/parameter. It is not a receiver acknowledgement.
- **Receiver confirmed:** actual authorized, fresh parameter feedback for the same receiver endpoint/channel/parameter identity. Standard outgoing MIDI and remote transport ACK do not supply this.

`SensorRouter.provideRelativeReference` is a host-only API. The adapter must establish actual identity and provenance; it must not pass arbitrary remote data, inferred values or its own outgoing intent. Route and session are checked by the router. Evidence is single-use, at most 250 ms old at admission, not future-dated, within the configured wire range, and must advance the session/mapping evidence watermark. A sample older than the latest session receipt is rejected. Adapter must acquire a new sample after actual release/cleanup. No fallback to manual when a live reference is requested. Missing evidence or contention requires a new real clutch. Relative routes initially require exclusive targets.

## Adapter and acceptance inventory

| Surface | Required start/release evidence | Remaining work |
|---|---|---|
| Trackpad/Magic Mouse | stable contact identity and accepted native frame; lift or source loss | direct legacy helper ownership, contact-set change, per-axis mode switch |
| Touch Bar | touch begin/end and selected control | existing continuous owner and synth bank integration |
| Browser/iOS/Android XY | explicit contact owner, arm/release ACK and host admission | host-owned route capability/configuration revision, no second transform |
| Camera/Air helper | eligible tracked hand and gesture activation; identity/permission/loss | no reuse of cached samples; per-axis capture and re-arm |
| Measured XYZ/D-Beam | verified calibrated volume, X/Y/Z independently; loss or exit | preserve measured-depth capability and 150 ms gate; no fabricated depth |
| Gyro/tilt | angular position, explicit arm/release | unwrap at angle seam with calibrated units; rate/magnitude are not angles |
| Gamepad/lid/external | explicit start and scoped release | device-specific arbitration and feedback support |

Existing ordinary lift, expiry, Stop, Panic and ledger cleanup remain authoritative. No new hold-last behavior is introduced; pitch bend and safety cleanup must remain neutral as appropriate. MPE member tuning bends are reserved until expressive offset composition is independently proven. Mode/target edits require disarm and fresh re-arm; retain legacy archives and do not change wire protocol without negotiation.

Tests must cover no initial send, movement both directions, clamp and return, invalid/stale reference, cross-device contention, release/re-touch, cancellation, calibration and mode edits, smoothing, angular seam, missing feedback, actual DAW route/parameter confirmation and separate physical acceptance. Source/fixture tests are not hardware or receiver evidence.

### Native helper planner candidate and temporary capability fences

`NativeHelperRelativeClutch` accepts complete, strictly ordered frames from one Trackpad or Magic Mouse contact. The initial genuine neutral frame is mandatory; the first contact anchors every configured relative lane without emitting. X, Y and contact size have independent wire references, bounds, gain and smoothing. A second contact, a different ID, a foreign surface, invalid data or regressing receipt retires the clutch; wait for actual neutral before accepting another touch. A host must honor releaseRequired, retain any failed cleanup debt, enforce native freshness and block permission/identity loss; this planner alone cannot prove any of them. It is not yet wired to the native helper UI or MIDI sender. A new gesture with manually configured lanes uses those configured reference values, not a measured receiver value.

Current remote pedal lane identities do not establish whether a source is a continuous control or binary gesture after a same-family mode switch. Relative on pedalExpression/pedalVolume/pedalWah is intentionally rejected until a reviewed source-mode/route binding exists. Relative on wrapped yaw/pitch is also rejected until a seam-safe angle adapter is bound. Absolute behavior stays unchanged. Rotation and acceleration magnitudes are level differences, never angles. This is a temporary capability restriction, not a permanent omission from the feature scope.
