# R9-PERF2 — capacity and scheduler proposal

**Verdict: experiment PASS (evidence and bounded XY proof-of-concept); frozen performance gate remains FAIL; production integration, native and physical acceptance HOLD.** No promotion or merge authorization.

- Base: PR #82 head `e55acd52d9e8ba241afa3b8574618625c0dab47e`; frozen production source remains PR #80 head `287560d4e522cf46b585e7212c4413ecce3c3d1b`.
- Branch: `agent/remote-r9-perf2`. Only new files under assigned scope; original PERF evidence retained unchanged.
- Main experiment: `910bf4597ba2d2343dc66327aa28c301c130e870`. Exhaustive subset experiment: `1bac37a2153b5c0eda08bc1ee2ec4f013317737a`. Fault experiment: `246b0915cf97527f5fdae441606c7373e16582b0`.
- Frozen CI: https://github.com/Tihulu/Tihulu-Trackpad-M-Mouse-Instrument/actions/runs/45420260754 — success, exact frozen SHA; ordinary CI does not execute these new experiments.
- PERF base CI: https://github.com/Tihulu/Tihulu-Trackpad-M-Mouse-Instrument/actions/runs/45421508414 — queued when checked.
- No production code or existing workflow changed; no stable install, merge or release.

## Reproduction and limitations

In the disposable agent checkout, with Node 18+:

```sh
git diff --name-only e55acd52d9e8ba241afa3b8574618625c0dab47e HEAD
git show 287560d4e522cf46b585e7212c4413ecce3c3d1b:studio/Sources/NoSpeakerMac/RemoteLoopbackPageServer.swift > /tmp/r9-frozen-page.swift
node studio/scripts/remote-stress/capacity-experiments.cjs /tmp/r9-frozen-page.swift
node studio/scripts/remote-stress/capacity-subsets.cjs /tmp/r9-frozen-page.swift
node studio/scripts/remote-stress/capacity-faults.cjs /tmp/r9-frozen-page.swift
```

First two scripts emit exploratory matrices, not a green CI gate; last script exits nonzero on a failed fault assertion. Results are in capacity-summary.json, capacity-{frozen,edgeFirst,deadlineAware,pacedEdgeFirst}.json, capacity-subsets-results.json and capacity-fault-results.json. The first three raw matrices were recorded at experiment commit 59d087271f885c0296a4a51099b873fe00ff6c95; the later experiment adds pacing and leaves those variants unchanged.

Executed exact retrieved frozen JS using V8 Function with injected globals and inherited virtual clock/WebSocket/host-policy model. In-memory transformations use exact checked anchors. The 768-scenario matrix was executed twice, byte-identical. The 1,524-scenario exhaustive subset sweep and six additional fault probes were executed once. Node VM CLI is a reproduction path, not an independently run local command. Local Node and Swift exist, but `git ls-remote` failed with 'Could not resolve host: github.com'; no local native build or tests. No physical Mac/phone, haptic or MIDI evidence. The host model clears active streams on disconnect by construction; no native release inference. It does not model every Swift validation, host main-actor stall, MIDI fan-out, CPU contention, multi-peer aggregate traffic, real timer throttling, or actual connection teardown latency. This is a workload-specific virtual-time experiment, not a latency SLA.

## Unchanged constraints and experimental choices

Browser: 150 ms oldest edge age (send-side), 220 ms pending ACK deadline, 250 ms stale sensor watchdog, existing 25 ms timer and 25/50 ms eligibility. Host: 350 ms active-stream watchdog, 2 s idle watchdog, receipt freshness <100 ms, 90 frames per one-second rate window, four admitted peers and 16 global router sessions. No deadline increases. 150 ms queue age is not a 150 ms host-receipt SLA: network transit follows send.

Four variants: frozen scheduler; ordered XY + oldest edge first and ACK-driven tick; same ordered XY + experimental deadline ranking; paced edge-first with 13 ms minimum spacing before any send, including release. Pace wake is canceled on close. A 13 ms spacing bounds sender to 77 frames in a half-open second, not a proof of host receipt count under arbitrary jitter. The pace choice, 250 ms refresh ranking target and conservative local reserve of five are experiment design choices, not existing product policy. Existing host rate checks remain the authority.

## Representative matrix (768 scenarios)

Each variant: 16 named combinations x two workloads x six RTT profiles = 192 scenarios. Hold all selected controls for 1.6 s then release; burst eight cycles of 15 ms simultaneous discrete gestures, 250 ms cycle spacing, sensors sampled every 10 ms. Count matched edge transitions, unexpected edges, closure, one pending maximum, model ownership, stream delivery and service gaps. A pass requires every attempted edge and continuous stream delivered, no close, modeled ownership empty after release, one outstanding max, continuous receive gaps below 350 ms. First and tail gaps and per-edge host receipt latency are recorded. No failed overload rejection is counted as a successful performance scenario.

| RTT (ms) | Frozen | Edge-first | Deadline-ranked | Paced edge-first |
|---|---:|---:|---:|---:|
| 5 | 31/32 | 29/32 | 29/32 | 32/32 |
| 20 | 26/32 | 32/32 | 28/32 | 32/32 |
| 40 | 21/32 | 22/32 | 19/32 | 22/32 |
| 60 | 17/32 | 20/32 | 15/32 | 20/32 |
| 20 +/- 10 | 26/32 | 31/32 | 28/32 | 31/32 |
| 40 +/- 15 | 21/32 | 22/32 | 19/32 | 22/32 |
| Total | 142/192 | 156/192 | 138/192 | 159/192 |

Unpaced ACK pump at 5 ms with five or more held streams causes modeled host rejection (consistent with >90/s rate; watchdog gaps ~56 ms). Deadline-ranked version assigns unarmed streams infinite due time and can silently starve arms while other held streams refresh; do not adopt it. Pacing improves low-RTT hold but cannot overcome a slow single ACK lane.

Seven-stream paced results: at 5 ms hold maximum service gap 91 ms and burst continuous gap 148 ms; at 20 ms 140/220 ms respectively. All 64 discrete burst edges received at both. Worst pedal burst receipt p95 78/155 ms respectively; this is not a musical latency target. At 20 +/-10 ms burst disconnects with one missed pedal edge; at 40 and 60 ms hold/burst fail. At 40 ms hold reaches 280 ms service gap before release queue closure. No blanket seven-stream promise.

## Exhaustive admission envelope (1,524 additional scenarios)

All 127 nonempty subsets, six RTT profiles, both hold/burst. For each subset require both workloads. A profile family additionally requires every subset of an admitted combination to pass in every profile in the family (downward closure). Data includes actual tested masks; this is a conservative proposal derived from experiments, not a production entitlement.

| Profile | Hold passed | Burst passed | Both passed |
|---|---:|---:|---:|
| 5 ms | 127 | 127 | 127 |
| 20 ms | 127 | 127 | 127 |
| 20 +/-10 ms | 127 | 126 | 126 |
| 40 ms | 64 | 81 | 60 |
| 40 +/-15 ms | 64 | 63 | 60 |
| 60 ms | 64 | 35 | 35 |

- Low family (5, 20, 20 +/-10): 126/127 downward-closed subsets; all sets up to six, not all seven.
- Moderate family (low + 40 and 40 +/-15): 60/127. All singles and pairs; 31 triples (not three discrete instruments); one four-stream set (touch + orientation + acceleration + rotation).
- Broad family (all above + 60): 35/127. Seven singles, 15 pairs, 13 triples. At most one discrete stream (touch, drum, piano, pedal) plus up to two sensors, or all three sensor streams. No four-stream set.
- Profile classification is not an existing capability. Do not advertise these as guaranteed real-world limits. No RTT sample or unknown jitter must not imply a high-capacity class. Start conservatively; explicit user-visible unavailable/unknown state; validate on real devices and long-duration, multi-peer and phase-shifted loads before shipping any limit. Reject a new activation rather than silently remove previously active owners. If conditions deteriorate, existing safety failure/explicit release behavior remains; never extend deadlines.

Why admission is necessary: on one non-pipelined lane, seven sustained streams at 60 ms RTT need at least 420 ms per cycle before overhead, incompatible with the 350 ms watchdog. For two simultaneous 15 ms discrete gestures, four onset/release frames at 60 ms RTT need at least 180 ms to send the last frame even when initially idle; last release deadline is 165 ms from gesture start. Three simultaneous gestures at 40 ms RTT need 200 ms for six frames, again beyond 165 ms. Releases already in progress and refreshes consume more capacity. These are optimistic lower bounds, not sufficient admission tests. Preserve strict sequence and per-stream ownership; a batched or multiple-lane protocol would need independent security/ordering review and is not proposed for immediate integration.

## Resource policy (host model)

Existing core source and previous unexecuted native probes show 4 peer slots and 16 global router sessions; a mapped peer may use 7 sessions. Air strike shares acceleration. Local physical sources (trackpad, Magic Mouse, lid, Touch Bar, camera) can each require one slot. Recommend reserve L = number of configured/eligible local sources, or conservative L=5 until confirmed; remote budget 16-L. Protect local future activation, not just current owners. Per-peer reservation is selected stream set, not all manifest capabilities. Four peers may pair idle; a peer only has active capacity when reserved.

| Local reserve | Remote slots | Example feasible allocation | Example rejected |
|---|---:|---|---|
| 0 | 16 | 7+7+2 or 4+4+4+4 | 7+7+7 |
| 1 | 15 | 7+7+1 | 4+4+4+4 |
| 3 | 13 | 7+4+1 | 7+7 |
| 5 | 11 | 7+4 or 3+3+3+2 | 7+7 or 7+4+1 |

These are resource counts only, independent of network schedulability. A combination must pass both budgets. No extra router sessions or peer limits. Model exercised 20 allocation sequences and atomic denial/confirmed release recovery; all invariants held, fifth peer rejected even with zero streams, pending release retains reservation until confirmed. Static source and model only, not actual Swift execution.

Proposed host contract: single serialized authority maintains paired peer, requested mask, reserved mask, actual active mask, teardown state; atomically check requested union against authenticated mappings, per-peer cap, global reserve and chosen workload profile before arm. Count reserved but not allocated sessions against budget; one reservation per logical stream even for polyphonic notes. Denial leaves existing state unchanged and reports bounded explicit reason. Never evict local or other active owners for new activation. Release/timeout/disconnect frees only the correct stream after native router cleanup, never merely on client request. Retired sessions fenced by authenticated connection generation. On connection loss or configuration change revoke and verify ownership cleanup; no automatic replay/rearm. Existing v1-7 protocol does not expose such reservation negotiation; requires separately authorized bounded authenticated contract and independent QA/UX review. Client-only admission is not an authoritative resource defense. Model does not simulate native atomicity, multi-peer scheduler fairness, or MIDI output.

## XY correctness proposal and tests

Maintain FIFO of at most eight onset/release edges with captured normalized down coordinates, owner ID/state, enqueue timestamp. Continuous pointer movement may coalesce only while held; cannot overwrite unsent onset or discard a preceding release. Release may bypass unrelated samples but never its own older onset. A new valid touch after prior lift is accepted only if it fits queue/deadline; foreign pointer events do not release owner. Pointerup, pointercancel and lostpointercapture each end ownership once; pagehide/blur/disconnect clears queue and host must revoke owners. Overflow or age >=150 ms closes visibly, not silent loss or stale onset. No promise of delivery on overload or transport failure; no replay after reconnect. The experimental queue stores ordered wire edges; pointer ID checked at DOM event boundary. Native ownership/ACK semantics remain HOLD.

Frozen: 0/9 ordered short-touch vectors; release-only during pending drum, piano, pedal, orientation, acceleration and rotation ACK; repeated taps and cancellation collapse. All three prototypes: 9/9 correct ordered touch/release sequences; overflow closes explicitly (10th case PASS vs frozen FAIL).

Additional paced fault checks: six of six PASS in virtual environment:
- Missing touch ACK closes exactly 220 ms after send.
- Stale queued XY closes at 151 ms (25 ms scheduler check phase), zero stale touch frames.
- Transport buffer 257 bytes closes; pagehide closes active touch.
- Pending onset retains original x=.25/y=.75 despite motion to .8/.8; foreign pointer lift ignored; piano remains active.
- Stale orientation closes; modeled ownership cleared.

The prototype is a demonstration, not a complete native release proof. A final implementation should test coalescing/rapid alternation with keyboard and pointer ownership, multi-peer concurrency, real host receipt stale boundary, malformed frame rejection, disconnect mid-release, timer cancellation races, 90/s host cap under varied delay patterns, actual note-off/CC/sustain reset and no unrelated owner loss.

## Coordinator recommendation

1. Keep frozen gate FAIL. Use paced edge-first as a starting point for a separately authorized remediation, not as a drop-in patch. Reject naive deadline ranking and unpaced ACK pumping.
2. Add bounded ordered XY edges and explicit failure indication; do not silently lose short taps.
3. Protect local sessions with host-atomic reservations and admission, independent of browser scheduling. Distinguish available mapping, requested, reserved, active, releasing and unknown in UX.
4. Validate profile-dependent capacity on native macOS and real phones/tablets, long sustained operation, randomized phases and jitter, multiple peers/local sources, and actual MIDI/haptic latency. No claim of physical acceptance.
5. Do not merge, release, install over stable, relax safety deadlines or declare QA fixes based on this evidence.

**R9-PERF2: COMPLETE / HOLD.** Evidence delivered, implementation and native/physical acceptance not authorized or demonstrated.
