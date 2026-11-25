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
