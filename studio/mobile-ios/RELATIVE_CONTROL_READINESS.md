# REL-MOB — native phone/tablet relative response readiness

Scope and evidence: native mobile source snapshot 9331adf12ca44aac84153fafaa0de7f3da152ad8, coordinator relative candidate 770cf9defd3f18417113d740022a5365c5791659, central assignment #172 comment 7208806755. Proposed integration, not live relative support or hardware acceptance.

## Source inventory and boundary

| Surface/source | Current native observation / lane | Proposed host response and clutch |
|---|---|---|
| RGB horizontal/vertical | Selected hand, normalized oriented X/Y; one helper lane | Position eligible; first admitted post-neutral observation anchors, loss releases; no synthetic hold |
| RGB aperture | Normalized thumb-index opening; one helper lane | Position eligible; same freshness and selected-hand rules |
| RGB speed | Derived speed magnitude | Keep existing absolute until separately reviewed semantics; displacement of speed is not displacement of hand |
| RGB pinch/toggle helper | Binary 0/1 on a continuous helper lane | Absolute only; clear gate on loss; **host cannot distinguish this source from position using current wire** |
| Pinch keys/chords/strings/beam notes | Authorized discrete key mask; strings have independent expiry | Not relative; keep current gate/ownership/expiry |
| iOS LiDAR Beam / Android ARCore Beam | Normalized far-to-near; ARCore estimated/fused | Position eligible only for continuous helper, not Beam notes; sensor/role/bounds valid, release outside range |
| iOS measured XYZ / Android Camera2 DEPTH16 XYZ | Up to three independently enabled normalized X/Y/Z axes, calibrated volume; measured source | Each enabled helper axis candidate; independent host response, origin and release. Instrument axis selects discrete pitch. Hybrid notes remain unchanged; pitch axis may also be an independently assigned helper, subject to host ownership and bend compatibility |
| Native touch piano | Direct touch key masks, explicit Arm, 50 ms ownership renewal | Discrete, no relative or synthetic key events |
| Phone/tablet XY, tilt/gyro, accelerometer, rotation-rate, native pedals | No native XY/gyro capture in current companion; v7 native single-family parser rejects touch/tilt/acceleration/rotation flags. Browser XY/tilt and pedals exist on separate web surface | WEB/host owner for existing browser behavior; future native XY/gyro needs explicit capability, permission, orientation, angle wrap and separate clutch review. Native helper is not physical pedal. True pedal switch/sustain remains discrete |

MobileAirInstrument/AirProjection project source geometry into logical output, not target MIDI values. Native manifests expose only piano and pedal masks; v6 pedalboard and v9 xyzHybrid carry normalized levels, active bits and sequence. No destination, route response or selected native mode identity is negotiated. Host SensorRouter draft permits relative on pedalExpression/Volume/Wah, speed and other signals; a native same-family mode change can reuse these bits for binary pinch/toggle. This is a source-derived contract ambiguity, not a demonstrated live exploit. Until coordinator resolves, retain Absolute for binary and unclassified sources. Do not claim host settings are known or that a warning enforces them. No mobile delta transform, no new wire fields or local MIDI.

## Proposed per-axis UI, host-owned contract

After reviewed capability/route binding only: for each authorized continuous X/Y/Z or single helper lane, show source, target and route identity, Absolute/Relative, calibrated direction, gain and reference provenance. Local preview shows raw input; paired display distinguishes manual reference, locally accepted/delivered output and independently receiver-confirmed feedback. Unknown stays unknown. Host must validate feedback against exact endpoint, channel, parameter, route/session revision, freshness and permission; invalidate on reconnect, route change, permission loss or feedback timeout. An outgoing MIDI value or neutral ACK is not proof of DAW state. Do not enable Relative for unknown/binary/switch/sustain/notes or conflicting MPE pitch bend. No host change proposed as already implemented.

Start / clutch uses existing explicit Start, valid capability, foreground, stable sensor, neutral ACK and source acquisition. First eligible sample anchors without output. Stop / release, Panic, neutral fence on mode change, background, rotation, clipping, sensor/role/source loss and deadline expiry retire anchor and current ownership; require fresh re-arm. No hidden hold-last policy, no persistent anchor in calibration profiles. Mixed axes: independent relative/absolute selection, no double transform, no multiple owners of same relative destination. Preserve current safety deadlines and neutral cleanup. Current UI deliberately only explains eligibility and unknown host response; no active selector until host contract approved.

## Acceptance (NOT_RUN native/hardware)

| ID | Positive/negative scenario | Expected |
|---|---|---|
| REL-M01 | Valid position, stationary first frame, move +/−, return origin | No first-frame send; signed anchored displacement and clamps |
| REL-M02 | One XYZ axis relative, two absolute; disable axis | Independent values/cleanup, no change to discrete pitch key |
| REL-M03 | Switch helper to binary or speed without new authorized binding | Reject incompatible mode or require Absolute/rearm |
| REL-M04 | Sensor loss, stale/future/duplicate, background, rotation, permission revoke | Retire, no stale anchor replay; new valid capture reanchors |
| REL-M05 | Sparse keys, strings, sustain, switch and hybrid MPE collision | No relative note/gate or tuning overwrite |
| REL-M06 | Unknown receiver, manual start, delivered value, verified feedback | Four provenance states remain distinct; no false receiver claim |
| REL-M07 | Two devices same destination, same source family, reconnect | No competing relative ownership; old session retired |
| REL-M08 | Phone/tablet compact layout, TalkBack/VoiceOver, gyro wrap | Accessible independent controls; no jump at wrap; no synthetic sensor |
| REL-M09 | Physical Logic, disconnect/panic, actual timing | Existing gates unchanged; verify receiver/cleanup separately |

Current local evidence only: Android source classification tests cover all 11 Air modes; iOS observation display tests cover 150 ms exact expiry, duplicate/future/regressed stamps and reset. This does not execute host router integration or physical gestures. Dependencies: coordinator host route identity/source-mode binding and feedback; WEB browser XY/gyro, UX independent review, TUN MPE collision. See #172 comment 7208929399. No merges, release, hardware activation or permission changes.
