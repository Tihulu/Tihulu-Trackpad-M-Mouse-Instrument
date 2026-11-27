# MUSIC-MOBILE — candidate acceptance matrix (2026-11-27)

Pinned integration base: `34361977e4ae8754790194e6a95a6088e8b4eefc`. This is a source review and isolated candidate, not hardware/DAW acceptance. The Mac receiver, shared wire, CI and timing gates are outside this slot.

## Device and capability boundaries

| Device/backend | Supported client path | Required negative check | State |
|---|---|---|---|
| iPhone/iPad without LiDAR | front/rear RGB Air, local or assigned keys/helper; touch preview | Beam selection explains unavailable sensor, Start blocked; no simulated depth | Candidate; device NOT_RUN |
| LiDAR-capable iPhone/iPad | rear LiDAR Air and separate XYZ stage, measured depth only | deny/revoke camera; missing/invalid depth; background and rotation; neutral then restart | Candidate; device NOT_RUN |
| Android RGB | CameraX with explicit trusted local hand model | invalid role, unsupported camera, rotation during provider callback, background, stale frames | Candidate; device NOT_RUN |
| Android ARCore raw depth | estimated/fused Beam path; explicitly selected, no hardware provenance claim | unsupported ARCore, installation declined, invalid custom calibration, stale duplicate reading | Candidate; device NOT_RUN |
| Android rear DEPTH16 | distinct measured XYZ with advertised capability and real-time clock gate | missing capability, clock mismatch, rotation, ambiguity, stale sample and loss | Existing candidate; device NOT_RUN |
| Both touch-only | explicit touch pairing, assigned keys, no camera requirement for manual pairing | camera denied, mode switch to Air blocked until disconnect/re-pair; no note replay | Existing candidate; device NOT_RUN |

## UX audit disposition

- UX-049: iOS mode labels and selected-mode explanations reflect sensor, hand role, and existing authorized logical assignment. Existing projection/Start checks remain authoritative. Same-family mode change still requires neutral ACK and capture retirement. Different family requires new pairing. Android filters Beam modes by depth selection and shows existing assignment rejection. Candidate, independent review required.
- UX-050: all 11 Air modes have mode-specific gesture/release guidance on both clients. iOS shows actual logical key-region boundaries, string crossing lines, chord-selector eligibility, helper axes and depth-range indication from measured samples. Android still needs mode-specific visual regions and accessibility runtime verification. Partial, not closed.
- UX-051: Android retains three depth presets and offers optional custom integer centimetre fields (near 10–150, far 20–300; existing projection separation check); invalid values block Start and pairing rather than fall back. Fields lock during capture. No persistence/schema change. Candidate; native build/UI NOT_RUN.
- UX-052 and UX-053: macOS Trackpad/Magic Mouse and Touch Bar responsibilities; no edits under this slot.

## Lifecycle acceptance scenarios (device execution NOT_RUN)

| Scenario | Required result |
|---|---|
| Permission prompt, deny, grant, revoke while running | No implicit Android start; iOS existing explicit Start request generation; active capture/session retires on loss, touch-only unaffected |
| Rotate with RGB/ARCore running or during Android RGB provider setup | Retire before further admitted frame, require explicit Start, no old-generation callbacks |
| Rotate iOS while active or awaiting camera permission | Air stage and XYZ stage check the actual window-scene interface orientation, not a global device orientation; changed or unavailable orientation retires capture, manual raw sensor orientation remains separate. Physical execution NOT_RUN |
| Background / lock / activity recreate | Stop capture and paired session, clear local output; no automatic rearm or replay on foreground |
| Stale, future, duplicate, pre-start frame | Existing 150 ms freshness and source fence; duplicate ARCore snapshot cannot renew observation age |
| Same-family pause/change | Neutral ACK and worker retirement before explicit new capture; no stale mode output |
| Sparse assignment or role mismatch | No unauthorized logical key or helper; strings need three slots, chords at least one complete assigned shape and distinct hands |
| Depth loss/outside calibration or wrong provenance | Neutral output; never substitute monocular or estimated depth for measured hardware |
| Real multi-device/DAW | Measure actual timing and release independently; do not infer from preview or fixture |

## Verification boundaries

The standalone Kotlin/JVM calibration check compiled the exact helper blob `c5f567aaa62d674189347f927d7289ebd5c87174`: 18 targeted checks, 96,721 integer input pairs (29,675 accepted, 67,046 rejected). This is not Gradle/JUnit, Android UI, sensor or MIDI runtime evidence. Four new JUnit calibration/provenance tests are authored; exact-head platform execution and product/RAG CI are still required. No hardware opened. No safety thresholds, shared transport/wire, host receiver, CI, release or stable changes.

## MOB-02 continuation — lifecycle candidate

Android now checks foreground, permission and valid matching display rotation before pending RGB provider completion and before draining RGB, ARCore or measured XYZ observations. Permission is rechecked after asynchronous root verification for Air pairing; touch-only remains independent. Retire clears capture context; the existing ticket rejects obsolete callbacks. iOS Air now reuses the XYZ window-scene orientation probe; a pending permission result or running capture cannot survive observed interface rotation. No new clock or transport, no changes to freshness/ACK deadlines.

Local Linux Kotlin 1.9.0/JRE 21 standalone tests: source and original test blob hashes verified for `AirCaptureLifecycle.kt` (42672cc319e2b96a26e8bb323961cf9e92cf1a4a), `AirCaptureLifecycleTest.kt` (c9ac8476fcb0c55ab310b84fbc9aa2b4a0c665c5), `PairedObservationFence.kt` (9a1bf0e7df62b73e9c2940d827e8e7ae982b844e), and `PairedObservationFenceTest.kt` (a1d24268f6d148a89d5d332e59524bb7eabec895). Replaced only JUnit imports/annotations for local kotlin.test runner; invoked each method directly. Four lifecycle methods / 25 assertions PASS; 224 exhaustive input combinations, exactly 4 admitted. Five fence methods / 19 assertions PASS (constant-only shim for AirSendGate.FRESH_NS = 150 ms, not transport execution). Five newly authored test methods included in these nine. No Android runtime or iOS compile/device results. No verified UI acceptance closures. Full Gradle/native tests still require coordinator's mobile-enabled CI because agent draft branch is excluded by existing workflow conditions.

NEXT: accessible and responsive native touch and Air controls, Android mode-specific graphic feedback and independent verification of native lifecycle/camera/depth. Avoid source changes to the frozen review SHA when nominated by coordinator.
