# R9 consolidated checkpoint

Latest production/test head at this checkpoint: #106 `05004a69bca06be09d6fdb24af13ef7c71957695` (draft). This documentation-only follow-up does not alter app code.

- #103 run 45438410325: shared core and macOS build completed successfully. Artifacts listed: development app 14942931780 and preview DMG 14942926850. Older than current head; not current-head acceptance. Full 64 destination / 49 label host regression passed, 219 Swift Testing and 8 XCTest.
- #104 run 45438845041: shared core PASS; new package provenance and mounted-image verifier macOS pending.
- #105 run 45439072920: shared core PASS, 222 Swift Testing including all three source-aware diagnostic tests; macOS pending.
- #106 run 45439642370: actual 16-session and four-peer tests authored, current CI pending at checkpoint.
- #102 browser 61/61 and simulated 420/420 conservative workload, 14/14 lifecycle; 159/192 representative experimental. High-delay experimental combinations fail. No claim of native MIDI latency.
- Stable main `c504a8430e1a6d55573c8cd9f10f6a7465d3cbc6` vs #103: 120 ahead, one behind, 231 changed paths. Stable PerformanceCaptureMonitor.swift and RELEASE_NOTES.md identical blobs in #106. Candidate contains process-lifetime MIDI client, isolated-source exclusion, capture monitor stop and dedicated-thread diagnostics, required icon generation. These are targeted source checks, not semantic proof of every stable fix or independent review.
- No installation, main change, merge, release, or physical tests. Do not reuse an older artifact as current. Current-head macOS checks, independent cumulative review, stable-history reconciliation and physical acceptance remain HOLD.
