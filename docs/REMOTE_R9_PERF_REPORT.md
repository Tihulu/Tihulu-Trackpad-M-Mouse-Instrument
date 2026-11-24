# R9-PERF — frozen Remote stress report

**Verdict: FAIL (browser scheduler and missed inputs); HOLD (native core execution and physical hardware).** No promotion recommendation.

- Candidate: `287560d4e522cf46b585e7212c4413ecce3c3d1b` (PR #80, feature/remote-adaptive-interface).
- Harness: `73b50344b80b13ef8963d7e24512e83ed97a44a4`; Swift probes: `ce63248afa77f8b1bd84c2fe8f4cec3d12aca133`.
- Evidence: [frozen-results.json](../studio/scripts/remote-stress/frozen-results.json). Two independent invocations in the same V8 execution environment produced byte-identical results.
- Candidate CI: https://github.com/Tihulu/Tihulu-Trackpad-M-Mouse-Instrument/actions/runs/45420260754 — in progress when checked; not used as independent proof.
- Only new files in the assigned scope. No production, existing workflow, stable, release, merge or installation changes.

## Reproduction

In a disposable checkout of the agent branch, with Node 18+:

```sh
git rev-parse HEAD
git diff --name-only 287560d4e522cf46b585e7212c4413ecce3c3d1b HEAD
git show 287560d4e522cf46b585e7212c4413ecce3c3d1b:studio/Sources/NoSpeakerMac/RemoteLoopbackPageServer.swift > /tmp/r9-frozen-page.swift
node studio/scripts/remote-stress/stress.cjs /tmp/r9-frozen-page.swift
```

The Node CLI exits 1 on reproduced performance defects (expected on this frozen candidate), 2 on harness error, 0 only if the assertions pass. For the executed run, the GitHub connector retrieved both exact pinned files; V8 Function evaluated the unmodified embedded browser JS with injected DOM/WebSocket/timer globals. Only the two endpoint placeholders were replaced. The Node VM CLI is the portable reproduction path, not a command claimed to have been executed here. The isolated Linux runtime could not resolve github.com, so a local clone and actual Swift build were unavailable.

All numbers are **virtual milliseconds**, not elapsed CPU time or measured network, MIDI, browser-device or audio/haptic latency. Timer intervals and deadlines are the production constants. Fake transport uses one-way delays of floor/ceil(RTT/2), periodic deterministic jitter, and explicit simulated host receipts; host model approximates watchdog, sequence/rate policy and ownership. It is not the Swift implementation. Model disconnect clears active streams immediately by construction; that is not proof of native note-off. A full manifest exposes all seven streams, not an assertion that any particular saved patch uses all routes.

## Seven-stream simultaneous activation and hold

After admission, start tilt, acceleration and rotation permissions; emit sensors every 10 ms, hold touch, drum 0, piano 0 and pedal 3, and advance virtual time for 1.8 s. Release all controls together if still connected. One outstanding frame maximum in every case.

| RTT configuration | ACK samples (p50/p95/max) | Max receive-to-receive service gap | Explicit releases observed | Result |
|---|---|---:|---|---|
| 5 ms | 77 (5/5/5) | 176 ms | 7, last 32 ms | PASS (delivery only) |
| 20 ms | 73 (20/20/20) | 176 ms | 7, last 146 ms | PASS (delivery only) |
| 40 +/- 15 ms | 3 (40/55/55) | Insufficient samples | 0; disconnect | FAIL |
| 60 ms | 2 (60/60/60) | Insufficient samples | 0; disconnect | FAIL |

Steady service gaps were approximately 175 ms even at 5 ms RTT; the nominal 50 ms per-stream eligibility interval does not guarantee a 50 ms per-stream cadence. A 350 ms watchdog is a safety ceiling, not a musical responsiveness target. At 40 +/- 15 ms and 60 ms the drum, piano and pedal first events were never delivered. The browser closed at its unchanged 150 ms oldest-edge deadline; this is safe rejection but a failed performance scenario.

## Discrete edges and release

Eight 250 ms cycles: simultaneously press drum 0, piano 0 and pedal 3, release/toggle off after 15 ms. Count snapshot mask transitions in order (refresh duplicates excluded); latency is input timestamp to simulated host receipt.

| RTT | Drum p95 | Piano p95 | Pedal p95 | Matched / attempted edges |
|---|---:|---:|---:|---:|
| 5 ms | 18 ms | 23 ms | 28 ms | 48/48 |
| 20 ms | 55 ms | 75 ms | 95 ms | 48/48 |
| 60 ms | 30 ms (n=1) | 90 ms (n=1) | 150 ms (n=1) | 3/6, disconnect |

The 60 ms case stops after its first failed cycle; all three attempted release edges were missing on the wire before disconnect. It does not count unattempted cycles as lost. The model's cleanup is separate.

## Findings

### PERF-01 — HIGH functional: concurrent startup starves discrete edges

Frozen file `studio/Sources/NoSpeakerMac/RemoteLoopbackPageServer.swift`, embedded `tick()`, `send()`, ACK callback. One global pending slot; waiting sensor arms are ranked at -Infinity; touch can also contend with first edges. The queue age check closes before servicing an expired edge. Reproduce via concurrent jitter/slow scenarios above. Do not relax 150/220/350 ms deadlines to make this pass. Coordinator should evaluate deadline-aware edge priority/reserved capacity, bounded admission of active streams, fair scheduling and measurable capacity feedback. A single lane at RTT >= 50 ms cannot sustain seven streams under a 350 ms refresh deadline even without overhead; architecture changes need separate protocol/QA review. Distinguish low latency musical actions from coalescible continuous updates.

### PERF-02 — HIGH functional: short touch silently lost

Same file, `pad` pointerdown/pointerup handlers, `lift()`, `tick()`. At 60 ms RTT, start piano note; 5 ms later touch down, 10 ms later touch up, while piano ACK is outstanding. Wire kinds: capabilities, pianoKeys, release. Expected 1 touch onset; observed 0, no disconnect. `lift()` clears position before pending clears; only releaseDue remains. Propose a bounded ordered onset/release representation or explicit feedback for a dropped gesture, preserving fail-closed cleanup and testing overlap with every other control. No production edits in this PR.

### PERF-03 — MEDIUM capacity risk: peer count is not active-stream capacity

Static source: PhysicalPatchRuntime.swift maximumRemotePeers=4 and SensorRouter.swift maxSessions=16. Each fully active mapped peer may allocate seven router sessions (air strike shares acceleration); three such peers demand 21; local owners share the same session pool. The 17th allocation can close a peer mid-performance. This is a static capacity observation, not an independently executed Swift failure. Existing cap must not be raised without resource and ownership analysis. Recommend an explicit admission budget or documented effective concurrent stream capacity. The additional native probes below should verify the rejection and recovery semantics.

## Fault matrix

| Scenario | Simulated result |
|---|---|
| Missing drum ACK | Closed at 220 ms after send; model active cleared |
| Stale queued drum release | Closed at oldest queued age >=150 ms |
| Edge queue overflow | Closed synchronously before initial drum delivery |
| Host delivery 100 ms late | Modeled rejection; no drum receipt |
| Page hidden while drum held | Browser closes; model active cleared |
| Rate window | Model accepts 90/91 frames |
| Router capacity | Static 16 sessions; native test HOLD |
| Peer admission | Static 4 peers; native test HOLD |

The stale-host, cap and cleanup cases are model/static evidence, not actual host execution. No claims about transport scheduling on macOS.

## Disposable native probes (HOLD — not executed)

The added HostStressTests.swift probes actual PhysicalPatchRuntime, SensorRouter and release commands, not the JS host model. Copy the test only into a temporary package; do not change tracked candidate files or existing CI.

```sh
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
mkdir -p "$scratch/Sources/NoSpeakerCore" "$scratch/Tests/NoSpeakerCoreTests"
cp -R studio/Sources/NoSpeakerCore/. "$scratch/Sources/NoSpeakerCore/"
cp studio/scripts/remote-stress/HostStressTests.swift "$scratch/Tests/NoSpeakerCoreTests/"
cat > "$scratch/Package.swift" <<'EOF'
// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "R9PerfScratch", platforms: [.macOS(.v13)],
    targets: [.target(name: "NoSpeakerCore"),
              .testTarget(name: "NoSpeakerCoreTests", dependencies: ["NoSpeakerCore"])])
EOF
swift test --package-path "$scratch"
```

These new native tests are uncompiled/unverified in this environment. They cover the 91st-frame rejection, fifth peer rejection, 17th session rejection/recovery, third fully active peer overload and preservation/release of shared destination ownership. Existing `node --test studio/scripts/test-remote-browser.cjs` and `cd studio && swift test` remain separate baseline gates; not independently executed here.

## Physical acceptance — HOLD

Use isolated preview only, not stable. Measure real phone/tablet browser-to-Mac RTT, input-to-MIDI/audio/haptic latency, timer jitter in foreground, full mapping with 1/2/3 devices and local instruments, explicit release and device disconnect/lock/network loss. Capture per-stream service gaps, onset/release loss and native note-off logs; distinguish continuous coalescing from missed discrete edges. Repeat at representative network conditions and record device/OS/browser versions without secrets. Do not merge or release based on this simulation.

## Coordinator handoff

The browser harness intentionally fails for PERF-01 and PERF-02. Eleven failed assertion flags in the raw output are symptoms of these defects, not eleven independent findings. Keep performance gate FAIL until fixes are separately authorized and reproduced on a new pinned candidate. Native/physical evidence remains HOLD.
