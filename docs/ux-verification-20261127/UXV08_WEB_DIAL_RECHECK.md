# UXV-08 — independent global release stale dial comparison

WEB frozen #188 9242b92f72d81e2201061ffbfa1dcfa2084a4f68 (W blob de5ff77b95250c61a31efeeb84c7cbf02ed3df66) and #209 1f07fb80cf01cce74a3d250763152a7ab2ada47c (W blob 94b03aca239f970c7c4ac3f59ce946add47fe6a8). Extract exact releaseMyControls lines1059–1083 and pedalOutputs listener lines2288–2306 at both pins in V8, mock admission, controls, ACK completion and explicit rearm, callback counters and pointer events. Before/after independent paired cases:

| Case | Old | New |
|---|---|---|
| One drag, global release, rearm, stale pointermove | ledger1, value70 instead of100; fresh contact blocked | ledger0, stays100, fresh pointer moves to90 |
| Two simultaneous drags, global release, rearm, stale pointermoves | ledger2, both70 instead of100 | ledger0, both100; fresh pointer moves to90 despite stale old pointerup |

2/2 prior defect reproductions, 2/2 new candidate regressions PASS (each case checks ledger and values); old behavior not counted as successful product tests. New line1070 clears dialDrags on global release. Existing 350ms timer, touch release age and ownership queues unchanged in extracted function. This is controlled V8, not real DOM/capture, wire/ACK or DAW. Candidate source defect independently verified fixed, full acceptance HOLD. #209 new CI pending at inspection; #188 frozen core/RAG PASS; no transfer of native success from earlier 0c91efb4. No duplicate run.
