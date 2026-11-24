# R9-PERF3 — actual candidate verification and release-aware scheduler

**Verdict: actual #84 touch remediation PASS in browser simulation and shared-core CI; #87 reservation tests PASS in CI and static accounting review, independent full native execution HOLD; combined-load performance gate FAIL. Experimental release-aware prototype improves the measured envelope but is not approved for production integration. Physical acceptance HOLD.**

Base: #86 exact c227a02af48a371bac540cc631206e9fa4629774. Frozen candidate #84 0ae663697dcee20d4db41a7515f828a529b38a34; #87 74818cb142801011250c8707f11af43b13f3f549. Their browser files have identical Git blob a38fccca57de0ab9b6c2f38f32789ca17f93524d. Only NEW agent files; all production and previous evidence untouched.

## Reproduction

Use a disposable checkout of this agent branch, with the candidate Git objects available. Do not install over stable.

```sh
git diff --name-only c227a02af48a371bac540cc631206e9fa4629774 HEAD
git show 74818cb142801011250c8707f11af43b13f3f549:studio/Sources/NoSpeakerMac/RemoteLoopbackPageServer.swift > /tmp/r9-perf3-page.swift
git hash-object /tmp/r9-perf3-page.swift
node studio/scripts/remote-stress/stress.cjs /tmp/r9-perf3-page.swift
node studio/scripts/remote-stress/perf3-scheduler.cjs /tmp/r9-perf3-page.swift
for policy in actual oldest guarded releaseAware; do
  node studio/scripts/remote-stress/perf3-scheduler.cjs /tmp/r9-perf3-page.swift "$policy"
done
node studio/scripts/remote-stress/perf3-sustained.cjs /tmp/r9-perf3-page.swift
sh studio/scripts/remote-stress/perf3-parser-benchmark.sh
```

Expected browser blob: a38fccca57de0ab9b6c2f38f32789ca17f93524d. Inherited stress.cjs exits 1 on remaining performance failures. The exploratory scripts emit measurements rather than certifying a CI gate. The representative matrix was executed twice, identically, for the first three policies and separately twice for the final release-aware policy; the subset and sustained sweeps were each executed once. 768 unique representative scenarios, 6,096 exhaustive subset scenarios, 96 long-hold scenarios, 56 lifecycle checks across four policies, plus original frozen harness reproduction. Actual browser JavaScript evaluated in V8 with injected DOM/socket/timers; CLI Node VM path is supplied for reproduction, not independently executed here. Host policy is the inherited model (not Swift); it lacks native allocation, transport teardown latency, MIDI output, real timer jitter, aggregate peers and CPU contention. Direct local git clone DNS resolution failed; only scanner source was reconstructed and compiled natively. No physical hardware tests.

## Actual candidate (read-only)

Inherited original harness results are in perf3-actual-frozen-harness.json. Seven-stream hold at 5 and 20 ms RTT: max receive gap 176 ms and all seven explicit release frames delivered by 32/146 ms. Jitter 40 +/-15 and 60 ms still close at stale edge limits. Short-touch onset recovered; the inherited short test ends before the release arrives, so use the extended lifecycle checks for release evidence. At 5/20 ms three discrete-stream bursts deliver 48/48, at 60 ms 3/6 before fail-close. Ten original failure flags remain.

New lifecycle checks: 14/14 actual candidate PASS, independently exercised with virtual ACKs: six 15 ms taps behind different outstanding ACKs, two rapid completed taps with preserved down coordinates and post-up lost capture, held cancellation/lost capture/rotation/pagehide, queue overflow, stale onset rejection and 220 ms missing ACK. The actual cancellation policy deliberately closes/discards unsent onsets, rather than replaying a canceled gesture. All experimental policies retain it.

CI inspected directly:
- #84 exact commit: https://github.com/Tihulu/Tihulu-Trackpad-M-Mouse-Instrument/actions/runs/45422413082 ; shared core job 138545204238 SUCCESS, all five new XY regression names pass, 202 Swift tests passed, Verification passed.
- #87 exact commit: https://github.com/Tihulu/Tihulu-Trackpad-M-Mouse-Instrument/actions/runs/45424091892 ; shared core job 138551205992 SUCCESS, five XY regressions and remoteReservationsProtectLocalBudgetAndExistingPeers / remoteReservationsRejectSecondFullPeerAndRecoverOnExpiry passed, 204 Swift tests passed, Verification passed.
- Both macOS build jobs queued when checked. Shared core results are CI evidence, not independently executed full native tests. Standard CI does not run these new experiments.

#87 source accounting (PhysicalPatchRuntime.swift blob a675f1eb9b2297b18dc4b915ef85f5dc98be8972, lines 24-40, 161-179, 377-400): 4 peers, global 16 router slots, 5 reserved local and 11 remote. Full mapped cost per admitted source, not per active stream. Touch/tilt/drum/piano/pedal each cost one; distinct inertial signals each cost one, air strike shares acceleration. Reservation computed from immutable configured masks and peers, released only on peer teardown. Static allocation sites match these seven stream classes. Existing peer count checked before invitation consumption; remote session cost checked after consumption. 7+4 fits, 7+7 rejects, even if the peers only play one instrument. Local source slots remain protected; no dynamic per-stream negotiation. No native multi-peer resource measurements from our browser harness; two native reservation tests are confirmed from CI logs. Full independent runtime, all five physical sources, combined host throughput and physical MIDI ownership remain HOLD. Do not conflate reservations with scheduler capacity.

## Scheduler experiments

All variants retain one pending ACK, 150 ms queued-edge rejection, 220 ms ACK deadline, 250 ms browser sensor watchdog, 350 ms modeled host active stream watchdog, 2 s idle, 90-frame rate limit and 25/50 ms existing eligibility. No deadline weakening. All three proposals use a 13 ms minimum send interval before dequeue, including releases, cancel pace wake on close, and pump tick after ACK; actual candidate unchanged. Oldest ranks ordinary discrete transitions by enqueue time (same 150 ms age), then finite arm waiting times and oldest eligible refresh. Guarded also elevates waiting arms and near-watchdog refresh using experimental 225/250 ms ranking thresholds. These thresholds are priorities, not new safety deadlines. Both initial variants ranked ordinary XY release behind explicit sensor stops, causing release regressions. Final releaseAware variant ranks explicit emergency/stop and eligible XY head-release by estimated earliest expiry (last send + 300 ms scheduling target, XY also its original enqueue + 150 ms); no new samples ahead of ready emergency releases. Within XY FIFO release never overtakes its own onset. Ordinary other discrete transitions use oldest ranking; refresh uses oldest service; arms use finite waiting times. Scheduling targets do not assert host receipt time or guarantee delivery. Actual host still enforces its deadlines.

Representative matrix: 16 combinations x 6 RTT profiles x hold/burst. Same inherited 1.6 s hold and 8 cycles of 15 ms edges at 250 ms spacing. A pass requires all attempted transitions in order, no disconnect, all selected streams observed, continuous service gaps <350 ms, max one in flight, modeled ownership cleared. Sensors sampled every 10 ms; this is one deterministic startup/phase profile, not a workload SLA.

| RTT ms | Actual #84/#87 | Oldest | Guarded | Release-aware |
|---|---:|---:|---:|---:|
| 5 | 32 | 32 | 32 | 32 |
| 20 | 29 | 32 | 32 | 32 |
| 40 | 23 | 22 | 22 | 22 |
| 60 | 18 | 20 | 20 | 20 |
| 20 +/-10 | 29 | 31 | 31 | 31 |
| 40 +/-15 | 23 | 22 | 22 | 22 |
| Total /192 | 154 | 159 | 159 | 159 |

Release-aware seven-stream hold/burst at 5 ms: max continuous service gap 91/148 ms; at 20 ms: 140/220 ms. All attempted edges delivered at both. 20 +/-10 ms seven-stream burst still misses one edge and closes; 40/60 ms seven-stream combined workload fails. Aggregate counts conceal individual regressions; no blanket approval. The 150 ms send-side queue bound is not a host receipt latency guarantee.

Exhaustive all 127 nonempty subsets x six profiles x hold/burst per policy (6,096 scenarios overall). Both workloads must pass; admission envelope requires all nonempty subgroups in profile family also pass (downward closure).

| RTT profile | Actual both | Oldest both | Guarded both | Release-aware both |
|---|---:|---:|---:|---:|
| 5 | 127 | 127 | 127 | 127 |
| 20 | 98 | 127 | 127 | 127 |
| 20 +/-10 | 98 | 126 | 120 | 126 |
| 40 | 33 | 59 | 59 | 60 |
| 40 +/-15 | 33 | 59 | 59 | 60 |
| 60 | 14 | 35 | 35 | 35 |

Downward-closed low / moderate / all-profile envelopes: actual 98/33/14; oldest 126/59/35; guarded 120/59/35; release-aware 126/60/35. Low family includes 5,20,20 +/-10; moderate adds 40,40 +/-15; all includes 60. Release-aware recovers the PERF2 envelope (up to 6,4,3 selected streams respectively in tested combinations; not every combination of that size). Actual and proposed per-mask tables supplied. Use conservative admission, not universal stream count: no known RTT is not low RTT; preserve owner and release reserve; host whole-peer budget is an additional independent gate. Need phase-shift, randomized jitter, multiple devices and sustained physical acceptance before exposing any capacity class.

## Sustained hold and release regression

72 original + 24 final 12-second virtual holds, three combinations (touch/tilt/acceleration; piano/pedal; all seven), 4 RTT profiles, 0 or 2 ms synthetic host processing delay. Hold pass requires repeated receipt for every selected stream with first/intermediate/tail gaps <350 ms. Then ordinary XY lift and explicit drum/piano/pedal/sensor releases; release pass requires all selected release frames observed, no closure and model ownership empty. No native note-off proof.

| Policy | Hold PASS /24 | Hold AND release PASS /24 | Min observed send gap | Maximum sender frames per sliding second |
|---|---:|---:|---:|---:|
| Actual | 20 | 20 | 5 ms | 46 |
| Oldest | 22 | 18 | 13 ms | 77 |
| Guarded | 22 | 18 | 13 ms | 77 |
| Release-aware | 22 | 22 | 13 ms | 77 |

Oldest and guarded failed four releases despite successful hold: at 40 +/-15 ms all seven held, modeled watchdog closed after only two explicit releases; at 60 ms touch/tilt/acceleration the two sensor stops preceded XY release, which aged out. Final ranking recovered all four cases in this workload. At 40 +/-15 ms seven-stream hold max gap 288 ms (302 with 2 ms host delay); final all seven release frames by 307/286 ms respectively. At 5 ms all release frames by 92/94 ms (actual 32/46 ms); at 20 ms by 150/156 ms (actual 146/164 ms). Pacing increases some low-RTT release latencies, and the 40-ms completion is too close to safety ceilings to be advertised as musical performance. At 60 ms all-seven startup still fails in both delay cases. Synthetic 2 ms host delay is sensitivity analysis, not a measured parser cost. Sender pacing invariant held for all 24 release-aware cases and all tested paced cases; network receipt burst rate is a separate host gate. Modeled disconnect cleanup is by construction; native release HOLD.

## Parser overhead (native scanner, not full host)

Actual #87 RemoteFlatJSON.swift blob 048a5306098feb5893b02df7ff8177f8dfba088d was reconstructed from connector and verified with git hash-object. Compiled using Swift 6.2.1 x86_64 Linux -O with only RemoteTouchFrame.maximumBytes=256 stub. Compared exact scanner to generated copy with identical regex patterns cached once in static property. Same grammar, uniqueness, UTF-8 and size checks; no removed validation. 224 key-set equivalence vectors PASS, including duplicates/escaped aliases and malformed values; these are scanner-level checks, NOT full typed schema or numeric policy tests. Alternating measurements, 100 warmups and 3,000 timed calls per vector per variant, DispatchTime uptime, microseconds. Raw CSV records p50/p95/p99/max. Initial independent baseline run also similar (touch p50 77.667 us, p95 100.301 us).

| Input | Actual p50/p95 us | Cached p50/p95 us |
|---|---:|---:|
| Touch 59 B | 78.547 / 99.945 | 19.761 / 21.023 |
| Pedalboard 90 B | 80.255 / 103.522 | 22.330 / 24.968 |
| Escaped key | 70.960 / 94.160 | 13.159 / 14.187 |
| Duplicate alias | 66.104 / 88.305 | 8.843 / 9.650 |
| Near-cap 236 B | 85.945 / 110.750 | 27.485 / 32.953 |
| Bad numeric array | 78.037 / 102.899 | 20.429 / 22.016 |

Oversize/invalid UTF-8 reject before regex compilation, comparable below 1 us median. Near-cap scanner-only sample deliberately contains extra key; full schema would reject. Wall-time outliers exist; do not treat p95 as hard bound. Accepted frame path calls RemoteTouchFrame.read in RemoteTransportPolicy.swift:60, PhysicalPatchRuntime.swift:195 and RemoteHostBridge.swift:109. Each read invokes scanner and typed JSONDecoder; illustrative three scans at touch median ~0.236 ms uncached vs ~0.059 ms cached, excluding decoding, host scheduling and transport. Do not sum marginal p95 as end-to-end p95. Browser manifest duplicate-key parser is admission-time rather than per-sample; not timed here. Recommend separately authorized scanner caching prototype with macOS Swift concurrency/ICU thread safety verification, expanded lexical corpus (numeric/BOM policy owned by QA), full typed decode and multi-peer benchmarks. No skipping duplicate checks or trust-boundary validation; consider validated typed frame handoff only with independent security review. Parser savings alone cannot overcome 40/60 ms ACK bottleneck.

## Handoff

Prefer release-aware pacing as next isolated review candidate, not approval. First two paced alternatives should not be integrated because of reproduced release regressions. Final ranking is a measured refinement, but remaining high-RTT bursts and conservative envelope still require scheduler/admission remediation and independent native/physical acceptance. CI baseline PASS does not imply performance PASS. The proposal intentionally does not change #84, #87, #80, previous #86 evidence, existing workflows or stable/main. No merge, release or installation authorized.

**R9-PERF3 COMPLETE / HOLD — production performance gate FAIL; experimental evidence delivered; native integration/physical HOLD.**
