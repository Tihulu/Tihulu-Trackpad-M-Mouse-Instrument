# REL-UX-05 — additional angular receipt transitions

Pinned #205 c0040273b24f60046fb0ec30dd53788df8458440, exact RelativeAngularClutch.swift Git blob ee08f646fd98c82cf727bf23eec6d74e57634dd3. Actual Linux Swift 6.2.1, /tmp/uxv08-angle, git hash-object verified, swiftc -swift-version 6 RelativeAngularClutch.swift main.swift -o check && ./check: 9 PASS / 3 FAIL, one prior and two related cases. No successor correction available at inspection.

| Scenario | Expected defensive behavior | Actual |
|---|---|---|
| begin(0,11), update(NaN,20), end, begin(0,19) | block older receipt | anchored (prior finding) |
| begin(360,20), end, begin(0,19) | block older receipt | anchored |
| begin(0,11), begin(1,20) while active, end, begin(0,19) | block older receipt | anchored |
| begin(0,11), update(180,20), end, begin(0,19) | block older receipt | blocked |
| after explicit end, new receipt21 | anchor | anchored |
| invalid infinite receipt during active, end, finite newer receipt | no poisoned clock | anchored |

The malformed angle path validates angle/receipt together before storing receipt; duplicate begin exits before receipt handling. Large-step rejection stores it. The desired defensive expectation extends the stated queued-sample watermark promise, not a demonstrated live bug (adapter must supply admitted, ordered, fresh samples). Clarify whether wrong-phase/blocked events are admitted, preserve explicit release and no automatic rearm. Report #172 7209208516 supplements original 7209087828. Do not weaken deadline or change production code in UX role.
