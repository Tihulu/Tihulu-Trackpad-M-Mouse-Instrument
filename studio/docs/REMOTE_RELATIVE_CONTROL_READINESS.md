# REL-WEB: Absolute / Relative browser contract (candidate)

Base: d4ee6bf12f8e02347e1bc27de662312dfe9549da. Coordinator core candidate 770cf9defd3f18417113d740022a5365c5791659. This is a source-side review, not live relative-mode or DAW acceptance.

| Surface | Current source | Proposed host-owned relative anchor | Required evidence |
|---|---|---|---|
| XY / pointer / keyboard | Normalized X,Y with contact/release | First admitted contact, per mapped axis | Verified reference, no jump, release ACK, second contact exclusion |
| Tilt | Orientation arm and raw angles | Stable calibrated orientation, wrapped angular displacement | Re-arm after loss, ±180° wrap, host release |
| Gyro | Rotation-rate magnitude, not position | Separate proven angle source or explicit rate-relative policy | Do not integrate rate in browser or claim angle |
| Acceleration | Magnitude plus optional Air Drums | Only eligible continuous route, never discrete strike | Gravity-free source, loss and mixed mapping negatives |
| Camera helper | Local image-motion-derived pedal levels | Eligible host continuous destination only, anchor after valid calibration | Stop/restart on geometry/source loss, no fake hand or depth |
| Pedal / synth slider | Assigned levels and held/toggle mask | Explicit continuous lane only | Neutral and release rules, no switch/sustain reinterpretation |
| D-Beam XYZ / LiDAR | Not available in browser | Native measured depth, independent axis mode | Native agent and coordinator dependency; never synthesize Z |

Existing v8 rows are source-scoped [signal,kind,channel,number,count]. They intentionally omit route IDs, response settings, endpoint identity and reference. The transport ACK says accepted, not a current instrument value. No browser-side transformation or new wire encoding is authorized. Keep raw/source-level samples and apply the shared transform exactly once.

Proposed negotiated contract (not implemented): consented route-scoped capability/active mode/config revision; reference provenance (unknown, manual, last host-delivered, receiver-confirmed) and freshness, endpoint/channel/parameter identity and ownership; explicit disarm/ACK/rearm for changes; no mode editing without confirmation. A stale or unknown receiver value cannot be labelled as current Logic value. The host decides whether manual reference is permitted, and retains release/Stop/Panic cleanup. Hold-last is separate, not default. Existing mapping privacy and version bounds remain intact.

Implemented here: scoped XY release/re-arm action cancels unsent edges, waits for already sent release ACK, preserves other lanes, accepts a new explicit contact only after release. Escape while keyboard-owned is equivalent. This is not relative recenter while held and may restore the host's neutral value. Source/readback distinction is surfaced in UI.

Acceptance: compare absolute vs relative at same starting coordinates; receiver reference at 0, center and non-neutral; mixed X/Y/Z; signed displacement, return to origin, clipping and recovery, repeated sample, wrap, permission/loss/reconnect, stale ACK, mode/target revision, duplicate owners, accessibility, MPE bend collision, sustain/panic. Actual browser/Logic/physical and negotiated host mode remain NOT_RUN.
