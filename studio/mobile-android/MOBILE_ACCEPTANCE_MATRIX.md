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

## MOB-03 — projected feedback, XYZ setup, native accessibility

- Android Air shows only logical projection outputs: sparse assigned key IDs, first three valid string slots, first eight depth key slots, chord note output, or helper level. Neutral, zero level, and invalid/foreign lane outputs remain distinct. No inferred hand position, distance or host acknowledgement. The visual grid is non-interactive; text meter is its accessibility counterpart. Reject stale/replayed depth submissions before showing their output. Unchanged render states skip repeated widget updates; no measured latency improvement claimed.
- XYZ role, pitch axis, selected axes and calibration edits now refresh Start eligibility; invalid volume, zero helper mask and incompatible assignment are explained separately from capture status. Measured XYZ does not require an unrelated Air mode selection to pair. Role/axes remain locked in an existing paired session; reconnect is required for a different XYZ assignment.
- Android paired piano height adapts to available configuration height (110–240 dp), iOS touch details use preferred font sizes and minimum 44-point Arm/Release controls. Both native surfaces expose armed/stopped/held logical keys as accessibility state, with no synthetic screen-reader-generated note or change to direct-touch lease rules. Full stage visibility is still required to arm. Responsive, maximum dynamic type, VoiceOver/TalkBack and physical multitouch rendering remain NOT_RUN; this is status accessibility, not a playable assistive keyboard.
- Local Linux Kotlin/JVM 1.9.0/JRE21: exact `AirStageFeedback.kt` blob 54112948a55c594c92348d9601a9c5126112e40b and original `AirStageFeedbackTest.kt` blob b04bbf354f7f817d1d2d89a6b46d17449db1f185 matched GitHub. Direct five test-method calls (JUnit imports/annotations adapted to kotlin.test; AirMode and AirOutput copied from production projection declarations) PASS, 2376 additional mode/mask/key combinations PASS. Not a full Gradle test or Android renderer. 
- MOB-01 exact native alias #180 run 45931557468 Android and iOS compile PASS, shared core PASS; macOS still pending when checked. MOB-02 run 45931773796 shared core PASS (57 XCTest + 1031 Swift Testing, plus engine and native CLI boundary checks), mobile skipped; RAG 45931773767 PASS. No evidence transferred to successor. No timing, transport, capture ownership or hardware acceptance changes.

NEXT: exact mobile CI for MOB-02/MOB-03; independently verify compact paired touch layouts, real accessible controls, camera/ARCore source loss, and sparse assignment/neutral ACK on hardware only after authorization.

## MOB-04 / REL-MOB

- iOS display-only timestamp fence now rejects duplicate/regressed/future/expired observations; retains observation marker on partial string release until observation expiry, not a note/transport authorization. Old display predicate reproduced duplicate and regressed acceptance (2 cases). Linux Swift 6.2.1: `swiftc -swift-version 6 studio/Sources/NoSpeakerMobileCapture/MobileObservationDisplayFence.swift studio/mobile-ios/tests/ObservationDisplayFenceChecks.swift -o /tmp/observation-check && /tmp/observation-check` 19/19 PASS; exact source/test blob hashes c6098ae87ae21b513a6bd7cc242b4385335f8eb3 / b37cfce8a6499bdfbeac330365263fc94291245a.
- Android source eligibility classification and ARCore readout: Kotlin/JVM 1.9.0/JRE21 local adapted JUnit methods 3/3 + 3/3 PASS; source/test blobs 314c56b4377ae01e01dcb53cb86759df86a049aa / 1440d2cc22f47de3fba593d1502ea443c144d75a; 8cf5a7361fa425c3d0580135abce8699cc0c2d19 / 3aa12296db9d9e5fab4f97a467f8114d13ff53e4. AirMode/AirOutput production declarations used, no Android framework or transport in harness. Previous MOB-03 fixture rerun 5/5 and 2376 combinations PASS. ARCore label separates no fresh observation, neutral acquisition/outside-range, valid zero and active output; failures/startup retained.
- Native Air/XYZ shows candidate source status, binary gate warning and unknown host response; iOS stage buttons adapt to narrow width. Relative selector/anchor/feedback not implemented until reviewed host mode binding. Full REL-MOB inventory and per-axis proposed contract in studio/mobile-ios/RELATIVE_CONTROL_READINESS.md.
- MOB-01 #180 4/4 PASS; MOB-02/03 core/RAG PASS, both mobile jobs skipped by branch filter, macOS queued at inspection. Exact current native compile, real layout, TalkBack/VoiceOver, hardware/DAW NOT_RUN. No protocol/ownership/deadline changes. No independent UX closure.

## MOB-05 — setup admission and permission retirement

Android: role selection must be explicitly 0–6 with a valid checked-axis mask. Helper/Hybrid require an enabled axis; instrument-only acquisition uses all three axes, discrete pitch axis remains selected. Missing spinner selection previously mapped to a Helper lane with checked axes; reproduced in an extracted predecessor expression (not a UI/runtime incident). Setup, Connect, Start and saved-profile operations now share role admission. Legacy seven-number helper profiles remain valid, canonical instrument-only profiles retain mask 7. JSON numeric strings/booleans/null, nonfinite/fractional role/mask, malformed lengths and inconsistent instrument mask are rejected before altering the form. Active capture snapshots role and mask; calibration or role cannot be reinterpreted from the UI during drain. Invalid normalized XYZ readout clears marker/depth/status instead of displaying Tracking. Device rendering, preference migration, dialogs and live output remain NOT_RUN.

iOS: XYZ Connect and Start share depth availability, active scene, valid volume and enabled helper axis preflight. Explicit permission before XYZ pairing; permission result never auto-connects or starts capture. Permission loss in connected idle or active XYZ closes existing session. Both XYZ and Air pairing/QR permission requests now have a ticket; Stop/background/disappearance retire it, obsolete callbacks cannot overwrite state. OS prompt/scene interruption requires explicit retry. No modification to current transport, touch ownership, source deadlines, raw sensor inference, saved keys or relative response.

Actual local Kotlin/JVM 1.9.0/JRE21 standalone: `XYZSetupSelection.kt` d9b765037225fc33c96c76e2d8435a4c31a8bebd and `XYZSetupSelectionTest.kt` e0d4766413e8004ca09c6459de35e64cc7ff19e1 source/test hashes verified. Direct four JUnit methods adapted to kotlin.test, production XYZVolume/MeasuredXYZ/XYZCalibrationRecord declarations extracted from MeasuredDepthXYZ.kt; 4/4 methods + 156 role/mask combinations PASS (52 admitted), old missing-role interpretation reproduced. No Android JSON/widget instrumentation (raw Number inputs only).
Swift 6.2.1 Linux: MobileXYZSetupAdmission.swift c7ac54138441701ede1416107c3223e8cce3ecce and XYZSetupAdmissionChecks.swift 7dc869089b1eae06d14681bff0522e7958799ae8 exact hashes verified, 160/160 combinations and 11/11 permission-fence assertions PASS. Prior locally built MOB-02/03/04 fixtures rerun: 4 lifecycle + 5 fence + 5 feedback + 3 relative eligibility + 3 depth readout Kotlin methods PASS, 224 and 2376 additional combinations PASS, 19/19 Swift observation display checks PASS. These are narrow offline tests; not the complete platform build. Full checkout remains DNS-blocked. CI/independent UX/physical acceptance separate. REL-MOB host negotiation and receiver feedback remain blocked; no added relative progress counted.
