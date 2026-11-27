# UXV-04 — independent WEB-03 and SEQ-03 rechecks

Application integration remains 34361977e4ae8754790194e6a95a6088e8b4eefc.

## WEB-03

Exact d4ee6bf12f8e02347e1bc27de662312dfe9549da, W blob 78169f0a98073031f3a4f6c4925680a255ff1ed7, lines 1604–1620. Non-rest values require integer 0 <= i < 25 before bitmask lookup. Test script line 2127 adds independently reported negative sequence regression. Extract phraseCandidate and exact has into V8 with mocked select values, valid first note 0, remaining rests, all 25 authorized bits. 18/18 PASS: accept -1,0,24; reject -2,-7,-8,-31,-32,-33,-64,25,31,32,64,0.5,empty string,NaN,Infinity. Prior UXV-03 three failures retained; no longer reproduce at this exact SHA. Source-level defect verified fixed, not full UX-012 closure. Product CI 45932218054 pending at initial inspection; RAG 45932217991 PASS. Posted #172 7208889257.

## SEQ-03

Exact ef8ee9b7a52c4f98800d940bdd6d85807f2301db, ComposerDraft.swift blob 2ba4e29c9576d21bd6e2cadd2cf6c202208562d0. Transcribed exact source to /tmp/uxv04-composer, git hash-object matches; Linux Swift 6.2.1, swiftc -swift-version 6 ComposerDraft.swift main.swift -o check && ./check. 12/12 independent checks PASS: valid context, synchronous stale-context disabled/apply rejection, valid Apply, observed context invalidation, preserved undo and restored prior grid, observed grid invalidation and ABA, context ABA, no-op rejection, drum fill change. Core only; no SwiftUI runtime. PatternComposerPanel.swift blob 07433de7e9da894cf6eb7fb4a0db835957981229:22/105 generation context, 55–56/134–135 synchronous guard, 67–68/146–147 onChange, 80–85/159–165 captured generation context. UX-042 remains candidate; coalesced unobserved edit-and-revert still needs actual root binding observation. UX-039–041 remain OPEN; no scheduler/playhead/scoped Stop proof.

Existing CI separate: #177 frozen 747d9e265f6b48da04842cc2f9328d4786ea5813 run 45932199605 core PASS, macOS in progress. #187 current run 45932525167 core PASS, macOS queued, mobile skipped; RAG 45932525164 PASS. Exact CI evidence does not prove native UI or DAW. No production files changed.
