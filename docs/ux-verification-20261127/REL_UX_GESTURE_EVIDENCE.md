# REL-UX — independent relative gesture evidence

Coordinator #176 pin 770cf9defd3f18417113d740022a5365c5791659 (tree f2f4ce9b2f28a982a2effd1a8a9da127f6ee71ac), relative source blob 5ab6703229e7bc406f556562e8ba7bd68dd9d4c2. Exact source transcribed locally, git hash-object matches. Linux Swift 6.2.1, cd /tmp/uxv04-rel && swiftc -swift-version 6 RelativeControlGesture.swift main.swift -o check && ./check. Initial harness-only main-actor isolation compile error corrected by annotating check @MainActor, no product source change. Git clone DNS blocked. 24/24 independent assertions PASS; no full router/native/hardware execution.

| Group | Assertions | Result |
|---|---:|---|
| Stationary, signed movement, origin return, invalid/stale samples and recovery | 7 | PASS |
| Upper/lower clamp, plateau, no drift after clipping | 5 | PASS |
| Independent axes with different references | 2 | PASS |
| Same-time smoothing, approach, origin transient, settled origin | 4 | PASS |
| Invalid gain/reference/time/input | 4 | PASS |
| Raw wrap seam and manual-reference discrepancy diagnostic reproductions | 2 | PASS (limitations reproduced) |

Default reference64, bounds0...127: anchor .5, stationary emits nil; .75→96, .5→64, .25→32. Gain4 clamp127/0 then origin returns64. Smoothing100ms: .5→1 at +.1s emits104, return .5 at +.2s emits79, settled emits64. Smoothing means return to origin need not be immediate. Raw .99→.01 at reference64 emits0 (requires adapter wrap strategy); manual reference20, .5→.51 emits21, regardless of unknown receiver value. Neither diagnostic is evidence of universal no-jump performance. RemoteMotion.swift:55–68 already shortest angle relative to calibrated neutral, so avoid duplicate transforms; test near opposite-neutral seam/saturation.

Source: SensorRouter.swift blob 62142b7abed5d70559f2c3282a3597699a7204be, 166 requires eligible signal, no pedal mode and eligible target; 327–344 anchors per owner and denies concurrent same mapping; 398–464 clears anchors on release/disconnect/panic, expiry calls disconnect. ContinuousResponse.swift blob 62c5fd27400be68a197c9f6a6fe7a86f72e55e7c validates reference within min/max and exclusive target mappings. These source checks do not establish adapter contact/loss semantics, MIDI feedback, or global ownership across separate runtimes.

UI source discrepancy: ContinuousResponsePanel.swift blob df0682fe4deaa7701561e8487d1f4501c260bde3 lines 19–34 gates picker only on target, not signal; Builder lines 774–775 passes target alone, while core requires eligible signal. Discrete source contact mapped to CC74 can be offered Relative then invalidated by model. Request capability-aware availability and explicit reason; do not relax core. Manual start slider 39–41 uses 0...1 despite configured min/max (invalid warning exists); gain/reference need named AX controls, per-axis draft/active and feedback provenance. No live feedback known; manual first movement can jump. Dependency request sent #172 7208902736.

Existing product run 45932852623 shared core/Android PASS, iOS/macOS queued at inspection; RAG 45932852632 PASS. Full native and physical acceptance HOLD. No timings or production edits.
