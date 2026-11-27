# UXV-02 — P1 candidate recheck and handoff

Original application pin: 34361977e4ae8754790194e6a95a6088e8b4eefc. All 15 P1 rows retain their original acceptance checks. No independent closure.

## Candidate preservation

UX-013: pinned source still has explicit touch-only manual pairing on iOS/Android. Rechecked mobile candidate 3a1775fce8fc589ee2c7cd489c9d057afcdac423 (MobileAirPreviewView.swift blob e6d1bcbbe5f1455604b618753c76a10a1077c953, lines 364–369,389; AirPreviewActivity.kt blob e56f0136360ce6b84ab97268712d842927eaf361, lines 497–521,552). Refreshed mobile #178 head 64de21759cb31db9e789485ffa99c48e63975fb6, iOS blob 8dbce8263ffcb65219980cfab326e93c5927dd42 lines 368–371,392; Android blob 7fea6306b9c42ba592f4f72d0c6119817dfcd1c6 lines 502–504,558. Explicit camera bypass applies only to touch-only pairing; sensor start remains guarded. No direct permission, pairing, lifecycle or ACK execution performed by this reviewer. Validation-only #180 tests earlier mobile SHA; cannot transfer results to newer mobile head. Candidate remains CANDIDATE; route actual denied-camera and sensor-denial evidence request to MUSIC-MOBILE/coordinator.

UX-037: pinned TouchBarProfileTests.swift:78–89 covers all 116 base values with eight default keys, D4 label, normalization at boundaries; 91–95 velocity bounds; 101–107 expanded 13 keys up to MIDI 127. Existing implementation uses shared normalized pianoKeys in native bridge and on-screen UI (P1 matrix). Existing exact-base macOS unit-test step PASS, not independent execution or actual Touch Bar pitch/hold verification. Remains CANDIDATE. Integration #173 has not changed; do not repeatedly reclassify identical blobs.

## Acceptance status

All eight formerly inconclusive rows have source dispositions. 53/53 indexed and source-triaged; 38 OPEN/partial, 15 CANDIDATE, zero independently closed. 11/11 focused diagnostic assertions in V8 (seven mocked browser mode checks, four markup reproduction assertions); 53/53 full runtime acceptance checks NOT_RUN, no device/DAW acceptance. Source triage 84.91% -> 100% (+15.09 pp), work-package engineering estimate 45% -> 60% (+15 pp), remaining 40% (reviewer planning judgment; further rendered UI, assistive technology, actual transport/physical checks and successor audit needed). Do not count overlap with web/mobile/tuning/other slots.

Coordinator latest #issuecomment-7208628203 records overall estimate 69.30% / 30.70% remaining (+0.10 pp for coordinator's baseline packaging evidence, not this slot); baseline product CI 45930559440 4/4 PASS including preview DMG packaging, RAG 45930559400 PASS. No new product changes or release/physical claims. Historical Pages source is not current deployed site.

NEXT: coordinator review of evidence documents, relay UX-022 duplicate C3/monitor overlap to Pages owner, UX-011 common selector path evidence to MUSIC-WEB, UX-013 denied-camera runtime verification to MUSIC-MOBILE, and UX-019/046/048 remaining UI dependencies to coordinator. On next continuation inspect fresh #172 and #173, recheck changed candidate files only against exact successor, obtain actual rendered/runtime evidence when environment permits. No production edits, no CI workflow changes, no hardware or shared branch writes.
