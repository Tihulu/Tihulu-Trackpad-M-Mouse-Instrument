# REL-UX-02 — scoped web clutch recheck

Exact WEB draft #188 reviewed head 6467c1051cefecb4737e2817ffc108df50b7260c, RemoteLoopbackPageServer.swift blob eb755ef8e51106cb026abc658257b24dab52894e. Integration #173 unchanged. Extracted exact touchBusy (517) and releaseXY (2108–2115) from GitHub file in V8; mocked pointer, queue, admission, clock (100), syncControls pending reset and tick counter. No actual socket or DOM.

| Case | Result |
|---|---|
| Queued unsent onset cancelled, pointer retired, no release needed | PASS |
| Sent contact queues release and blocks rearm | PASS |
| Existing queued release timestamp 30 retained instead of resetting to100 | PASS |
| Pending touch ACK remains blocked | PASS |
| Unadmitted, setup, unsupported capability, global release, already clutching, idle, disallowed mode | 7/7 PASS |

11/11 independent diagnostic checks, no failures. Actual source 1882–1885 clears pending only when !touchBusy; 2095 and 2122 reject pointer/key onset while pending; 2138 focus to release control invokes scoped release, other blur fails closed. Agent authored full harness regressions at 2138–2207 of test-remote-browser.cjs, including exact prior release deadline and ACK timeout. Actual candidate core run 45933832832 still running at inspection; RAG 45933832734 PASS. No independent full browser or transport/physical tests; do not count original WEB-03 tests twice.

The clutch retires source contact, does not implement receiver-relative motion, hold-last or seamless recenter. Existing host release/neutral remains authoritative. Mode and instrument value remain unknown without negotiated capability and verified evidence; no second client-side transform. Maintain exact ACK/expiry limits. UX-011 and UX-012 candidate-level only; no integrated closure.
