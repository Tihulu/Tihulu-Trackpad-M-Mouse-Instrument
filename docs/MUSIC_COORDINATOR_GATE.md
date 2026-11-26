# Coordinator QA gate successor — not accepted

Parent: QA-B draft #169, `6333f0e3815350ebd1cc1efe7d1755d64ecb78f6`, tree bc8325ba461ffca399571bde93876115019ea8f2.
Frozen #168 `03b2b12c50545f9f0ed6b670d5b66c8f44c9a9c2` remains unchanged.

## Evidence at preparation
- Maintainer #168 45716653937: both jobs success, 714 portable, all 16 isolated native fixtures.
- Independent QA-A 45717140495: 714 portable and 762 macOS general pass, 15/16 isolated fixtures, prepared playback faulted lateEvent at 54,549,958 ns (max identity 247,791 ns, send 39,291 ns).
- QA-B #169 45717528456: 717 portable pass, 15/16 isolated fixtures, receiver playback faulted lateEvent at 54,546,375 ns (identity 344,125 ns, send 19,250 ns). Checkout merge SHA 581239cba44c39c1c2bb6930ea9407da12d96d5e has exact QA-B tree bc8325ba461ffca399571bde93876115019ea8f2. Preserve the failed runs. No retry masking.
- Existing compile-only experimental gate was branch-specific and did not admit #169; the preceding native failure also skipped downstream build/package steps. Neither run demonstrates full successor acceptance.

## Changes
Exact head checkout for integrated and qa/music-* review PRs, including explicit checkout SHA verification. All six experimental flags compile on these review PRs even after a native fixture failure when checkout provenance succeeded; no execution or experimental packaging. Existing job failure remains failure; subsequent ordinary package/upload stay gated on success. Add actual checkout tree to preview provenance. No production source changes, deadline changes, new hardware permission or live CLI output.

The successor carries QB-01/02/03 candidate changes, not accepted closures. QB-04 remains open. Native timing investigation belongs to QA-A on an isolated evidence branch. This gate successor must pass again and is not a replacement for independent review, physical acceptance or owner release permission. No existing branch updated, merged, released or installed.

## Single-maintainer continuation (2026-11-26)

Owner stopped additional agent delegation. Preserve #168, #169, #170 and #171 and every QA evidence branch. #171 exact head 1d3b3f550007812007e5ec0e5a5be84b6a16cbed, tree dc2d0cd303d89c95fcfb5807bf8d4a9fca01b02c: run 45725927155 checked out merge SHA 27181d8d9c2132bbda69722180029e4076d68872 with that same tree, 723 portable / 771 macOS / all 16 native and preview PASS; experimental compile was skipped. #170 run 45719016369: 717 portable / 765 macOS general PASS, all six experimental compile flags PASS, one isolated fixture lateEvent at 59,456,709 ns. This does not establish a deterministic scheduler cause.

This successor starts from #171, carries the exact #170 workflow/provenance baseline, adds bounded absolute monotonic waits using SuspendingClock and zero requested tolerance (the 20 ms polling cap and 50 ms fault fence are unchanged), and reports maximum wake lateness on affected receiver fixtures. Three extra mandatory trials per affected fixture on QA successors; any failure remains a failure. No production real-time guarantee, no future-timestamp MIDI, no deadline relaxation. Builder touch/gamepad/scalar and physical hybrid publication command batches check the same receipt fence before each command and after the last. On rejection the single Builder patch stops using its actual output ledger, not speculative router state; unattempted commands create no debt. No global MIDI panic. Existing group ownership, camera/remote Builder receipt delivery, and Helper per-control/RPN/pedal paths remain open for QB-04. No physical acceptance, merge, install, live CLI or release authorized.
