# UXV-02 — focused executable evidence

Executed in connector V8 isolate using exact fetched text, not a browser, Node suite or live transport. No external IO, physical input, MIDI, or network in tested functions. App base 34361977e4ae8754790194e6a95a6088e8b4eefc, RemoteLoopbackPageServer.swift blob 744c8a299c2eeff65ea46603347357d33cd6f284; Pages revision 3895be7b31a52020c42d976b74d49845cb9aab69, docs/index.html blob a1319fc881eea69e8a742a0ba1980a73bb5067c6.

## Mode selector (UX-011)

Extract inclusive lines 999–1008, 1524 and 1036–1046 of W. Instantiate them in a function with mocked variables, select element, mode availability (piano/arp only), releaseMyControls (increments call counter and sets releasingAll), workloadMask, pending, sync functions, and status objects. Starting mode piano; no real release implementation is exercised. Before ACK, observe calls, playMode, pendingPlayMode; after optionally invoking finishGlobalRelease, observe mode/pending/releasingAll.

| Case | Observed | Result |
|---|---|---|
| Dropdown to arp | 1 release, piano retained, arp pending | PASS |
| Shortcut to arp | Identical to dropdown | PASS |
| Unassigned chord shortcut | No release, no switch | PASS |
| Unadmitted dropdown | No release, no switch | PASS |
| Pending ACK | Old mode retained | PASS |
| Nonzero workload mask | Old mode retained | PASS |
| Neutral and no pending ACK | arp committed, pending cleared, releasingAll false | PASS |

First harness invocation accidentally included the next function header, yielding SyntaxError before mode tests. Corrected extraction to end at line 1008; 7/7 PASS. This was a harness error, not a product failure. Release implementation, timeout, actual host ACK, focus and DOM remain NOT_RUN.

## Pages markup (UX-022)

Extract exact lines 39,47,48; call surface() and keyboard() in the V8 isolate, then collect data-note attribute strings using /data-note="([^"]+)"/g. 4/4 diagnostic assertions PASS: 8 surface controls, 13 keyboard controls, C3 occurs twice in keyboard, shared distinct IDs C3/D3/E3/F3/G3/A3/B3. These assertions reproduce a defect, not certify correct piano behavior. The desired regression should require distinct octave-boundary identifiers (C3 and C4), no duplicate playable representation unless intentionally independent, and appropriate pointercancel/lostpointercapture ownership. Real DOM and screen readers NOT_RUN.

Total 11/11 focused diagnostic assertions after correcting the harness, 0 full product suite tests independently executed. Preserve original baseline product CI evidence separately; this report does not replace it.
