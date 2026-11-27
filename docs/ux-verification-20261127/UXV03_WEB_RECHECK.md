# UXV-03 — WEB-02 independent diagnostic recheck

Pinned integration 34361977e4ae8754790194e6a95a6088e8b4eefc; web candidate ed415affc1687351d94de02eb0f17ba2c55583c6, W blob dc350a2319bb23307c12f1768ca51fc129bda294. Exact CI checkout synthetic merge 2768614696ae3ce0a1358ea87c82ac023c96b3ae; both commit trees 04e28c3c58a71076c7235c83c58339ce8a7ed75c. Reviewed actual shared core job 140285688181 of run 45931740936: 182/182 Node browser harness, 57 XCTest and 1031 Swift Testing PASS. macOS queued at inspection, mobile skipped. These are existing CI results, not independently executed by this reviewer.

## Independent V8 diagnostics

Extract exact W lines 1601–1617 and 1283 (phraseCandidate and has). Instantiate with mocked select values, caps.piano bitmask, arpSelected Set, chordShapes [[0,4,7]], chordAvailable matching source logic. Default 120 BPM, up, eighths, 50 swing; eight steps default -1. This does not run UI or transport.

| Case | Expected | Actual | Verdict |
|---|---|---|---|
| Note 0, remaining rests, bit0 assigned | valid | valid period 250 ms | PASS |
| All rests | reject | reject | PASS |
| Note 1, only bit0 assigned | reject | reject | PASS |
| Tempo 123 | reject | reject | PASS |
| Note 0 and fractional 0.5 | reject | reject | PASS |
| Note 0 and -32, bit0 assigned | reject | accepted | FAIL |
| Note 0 and -31, bits0/1 assigned | reject | accepted | FAIL |
| Arp 0, swing 57 | reject | reject | PASS |
| Arp 0, default swing | valid | valid | PASS |

Root cause: JavaScript shift counts are modulo 32, so negative -32 and -31 alias 0 and 1. Existing guard i===-1||(i<25&&has(...)) lacks i>=0. Normal select options are generated as -1 or mapped indices; reproducer is malformed input, not an ordinary user journey. W:1636 treats all negative indices as silence, not an unauthorized note. Request explicit nonnegative bound and negatives in regression, no host/timing changes. Reported coordinator/MUSIC-WEB #172 comment 7208694297. UX-012 remains OPEN/partial; no security exploit or physical result inferred.

Separately extract W:1506–1509 queuedAttack; V8 mock edge masks, readMask=e=>e.mask. Seven cases: empty queue false; queued scoped rise true; unrelated rise false; delivered then release false; delivered then release/re-attack true; previously visited bit attack true; retained owner with another rise false. 7/7 PASS. Does not exercise socket close, host receiver or physical notes.

UX-010: source W:1710–1746 now classic hit geometry, black-key precedence including unavailable black key, visited masks, per-owner slide; exact-tree CI logs confirm classic slide test. Candidate for WEB-02 only (integration unchanged), full device/browser/host acceptance NOT_RUN. UX-011 existing common transition candidate unchanged; UX-047/048 not fixed in this batch. Combined independently executed 14 PASS / 2 FAIL (16 diagnostic assertions); preserve failures, do not count CI tests as own execution.
