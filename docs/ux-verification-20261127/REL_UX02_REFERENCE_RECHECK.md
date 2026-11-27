# REL-UX-02 — reference and replay independent review

Integration #173 34361977e4ae8754790194e6a95a6088e8b4eefc unchanged; coordinator #176 reviewed pin 7e85ad90f5e63b66d088553ff6d53cbddf2667fe. Exact RelativeControlGesture.swift blob 06b52340774f9bbe5f1d5c25d3cbeb8602130216 verified by git hash-object after transcribing change into prior verified local source. Linux Swift 6.2.1: cd /tmp/uxv05-reference && swiftc -swift-version 6 RelativeControlGesture.swift main.swift -o check && ./check. 26/26 PASS, no harness failures.

| Diagnostic group | Count | Outcome |
|---|---:|---|
| 250ms inclusive, immediately over/under (Double.nextUp/nextDown), future, negative/NaN observation, infinite now | 7 | PASS |
| Wrong provenance, explicit lastDelivered, manual evidence rejected | 3 | PASS |
| CC bounds 0/127, outside, bend 16383, invalid/inverted/fixed bounds | 9 | PASS |
| Legacy JSON defaults manual, explicit provenance roundtrip, unknown remoteAck rejected | 3 | PASS |
| Stationary anchor, displacement from reference90 to103, return to90, regressed sample silent | 4 | PASS |

This is actual pure Swift code, not actual provider, router integration or physical device evidence. Router blob d913a0a844e808566a9add9cb26f63780d0a143f: 298–312 scopes session/source/mapping/destination and rejects wrong provenance, stale/old timestamp, active/blocked owner, nonadvancing watermark; 366–392 blocks contention, consumes evidence once, requires evidence not after input timestamp, anchor only; 518–521 clears anchor/evidence/blocked on release but preserves watermark; 490–493/511–514 removes session state on disconnect/panic. Scope/source inspection only, full router execution NOT_RUN. Release API has no explicit receipt timestamp; host adapter contract must acquire fresh evidence after actual release/cleanup, prove endpoint/channel/parameter identity and current route revision, not re-date an old sample. Session-local watermark alone does not prove post-cleanup freshness or DAW feedback. No automatic takeover, fallback or hold-last inferred.

## Blocking CI

Exact 7e85ad90 run 45933653679 job 140291759731 core FAIL, log checkout confirms 7e85ad9. Predecessor b50cc6d7 run 45933486771 job 140291238149 core FAIL. Swift Testing macro expansion of direct mutating Boolean method inside #expect (ContinuousResponseTests.swift 171,173,174,177,194,196 and later) calls immutable closure argument $0; tests fail to compile. This is not executed runtime failure. Suggested evaluate mutating call into local let then assert boolean, preserving every positive/negative test. Report #172 comment 7208970081. Coordinator owns change; no retries or production changes by UX. Android PASS, iOS/macOS queued at inspection. RAG 45933653742 PASS. Earlier REL-01 core PASS is not REL-02 acceptance.

## Editor regression

ContinuousResponsePanel.swift blob 3cf1a6bfb03228faa06d38578536fd6025c47853:9 defaults permitsRelativeInput=false; 11–12 combines target, 61–82 gates relative. Builder:776–777 correctly passes eligible signal and no pedal. GamepadMappingPanel.swift blob 69d6fad1c2da8e9bc350a40a2b041bcbfc190828:185–186 still calls with only target. Dedicated analog gamepad picker cannot select Relative and imported relative routes appear ineligible. Source-confirmed omission; no rendered test. Request capability from selected analog signal/action, not blanket enablement; sticks/triggers and discrete buttons, multiple destinations and imported profile recovery tests. Reported #172 7208960883. Manual range and AX labels in Builder source corrected, native renderer NOT_RUN.
