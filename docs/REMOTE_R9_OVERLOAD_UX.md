# R9-UX2 — mobile activation, overload and recovery contract

Status: DRAFT / documentation only. This addendum refines REMOTE_R9_PERFORMANCE_UI.md and REMOTE_R9_MAPPING_CONTRACT.md in #81, head `03d0e80948cf78d4b22b1c79acb31dd5d181f4b9`. It supersedes their open-ended concurrency and release wording where more restrictive. Frozen production evidence: #80 `287560d4e522cf46b585e7212c4413ecce3c3d1b`. No production edits, new playable controls, transport, permission, deadline relaxation, merge or release authorization. Coordinator owns implementation.

## 1. Evidence, limits and dependencies

Sources (pinned):
- [QA report QA-01–04](https://github.com/Tihulu/Tihulu-Trackpad-M-Mouse-Instrument/pull/80#issuecomment-7135401948): duplicate JSON member ambiguity reproduced in isolated Swift/JS parser probes; unmapped v1 touch allocation static finding; four peer/16 global session capacity and scheduling risk static/analytical. Full original suite not independently rerun. #83 `8a95a7fc1eb2ca5f416f26f63f5548a1233b6183` proposes fixes for QA-01/02; QA2 review pending at design snapshot. Do not label fixed before verified.
- [PERF report](https://github.com/Tihulu/Tihulu-Trackpad-M-Mouse-Instrument/blob/e55acd52d9e8ba241afa3b8574618625c0dab47e/docs/REMOTE_R9_PERF_REPORT.md), [raw results](https://github.com/Tihulu/Tihulu-Trackpad-M-Mouse-Instrument/blob/e55acd52d9e8ba241afa3b8574618625c0dab47e/studio/scripts/remote-stress/frozen-results.json), [handoff](https://github.com/Tihulu/Tihulu-Trackpad-M-Mouse-Instrument/pull/80#issuecomment-7135455692). Actual frozen embedded JS evaluated with V8 virtual time, fake DOM/socket, simplified modeled host; identical repeated output reported by PERF. Not native Swift, real network/device or audio latency.
- [Coordinator triage](https://github.com/Tihulu/Tihulu-Trackpad-M-Mouse-Instrument/pull/80#issuecomment-7135426921); [UX2 assignment](https://github.com/Tihulu/Tihulu-Trackpad-M-Mouse-Instrument/pull/80#issuecomment-7135494909). QA2 and PERF2 asked for explicit remediation/capacity evidence in [UX2 claim](https://github.com/Tihulu/Tihulu-Trackpad-M-Mouse-Instrument/pull/80#issuecomment-7135539840). Their new conclusions are not assumed.

| Workload | Reported observation | UX consequence |
|---|---|---|
| Seven streams, 5/20ms RTT | max receive gap 176ms; last explicit release received 32/146ms | delivery only, not proof of 50ms refresh or ACKed release/DAW outcome |
| Seven streams, 40 +/-15ms or 60ms | stale edge disconnect; drum/piano/pedal first events not received | do not default-enable every mapped surface; no RTT-based promise |
| 3-stream 15ms edge bursts, 5/20ms | 48/48 transitions; p95 drum/piano/pedal 18/23/28ms and 55/75/95ms | preserve ordered edges; delivery latency differs by surface |
| Same burst, 60ms | 3/6 attempted edges, first cycle disconnected; no releases observed on wire | never replay missed edges; cleanup not proven by simulation |
| Short XY tap behind piano ACK | wire capabilities,pianoKeys,release; 0 of 1 onset, no disconnect | PERF-02 blocks touch readiness until corrected; release alone is not successful tap |
| Missing ACK, stale edge, overflow, page hidden | browser closed; host cleanup modeled | explain uncertainty, no automatic retry |
| 4 admitted peers, 16 sessions | 3 fully active peers could demand 21 before local sessions | QA-03/PERF-03 static risk; mapped/paired is not reserved capacity |

In the raw concurrent cases, nominal 50ms eligibility yielded about 175ms actual service cadence even at low RTT. At 60ms RTT seven frames require at least 420ms on one ACK lane, above the independent 350ms watchdog. These are lower-bound calculations, not safe capacity estimates. PERF-01/02 HIGH functional findings and QA-01/02 strictness/capability gates remain unresolved in the frozen base. No whole-release approval. Baseline CI run [45420260754](https://github.com/Tihulu/Tihulu-Trackpad-M-Mouse-Instrument/actions/runs/45420260754) is not independent exact-head testing.

## 2. Activation eligibility and state

Keep Play / Setup / Connection, no new instrument or network probe. Separate these facts for every logical stream (XY, tilt, acceleration including Air Drums, rotation, pads, piano including sustain, pedals):
1. Mapped: derived only from strictly validated v7; metadata privacy opt-out does not mean unmapped. Unmapped hidden/disabled by both UI and handler; host enforces independently. Invalid manifest closes, never widens access. No readiness while pairing, syncing or parser/source-guard gate open on candidate.
2. Available for activation: mapped AND verified implementation feature AND allowed by coordinator-approved capacity/scheduling policy AND device prerequisites satisfied or explicitly requestable. Until there is a trusted policy, show "Concurrent capacity unverified"; do not infer availability from 4 peers, mask counts, RTT or browser tabs. A single surface is the conservative initial *design option*, not a measured guarantee. Only individually verified surfaces may be enabled; if no verified policy even for single-surface use, stay in preview/not ready. No capability-based activation bypass for legacy clients.
3. Requested: user explicitly chooses Enable/Arm; reserve local provisional slot before permission or queued onset, count pending arms and possible host allocations in capacity, prevent double activation. Enabled but idle is not evidence of a host reservation. Host reservation, if introduced, must be authoritative and per-peer; no browser-local workaround or extra polling. If existing contract cannot represent a safe refusal, use fail-closed disconnect and truthful status, not invent a response. Host can reject even a locally eligible request.
4. Acknowledged: a matching accepted response to that specific pending frame on the current socket. An arm ACK means host accepted arm, not that a subsequent stream sample has been delivered; idle Enable is not an ACK. For held/latching state, retain desired, sent, ACKed snapshot and transition timestamps independently. Mark pending release until the corresponding ACK or disconnect. Late ACK on retired socket cannot update current state.
5. Actual MIDI/audio/hardware output: unknown to browser; routing, shared owner priority, DAW delivery and sound are separate. Never infer "playing", "note off", "owns channel", "all safe" or host-wide active owner count. Optional future feedback is outside scope.

UI microcopy: "Mapped · not enabled"; "Permission needed"; "Waiting for sensor"; "Arm requested"; "Arm accepted"; "Input held · sending"; "Input accepted by Mac"; "Release pending"; "Release accepted by Mac"; "Disconnected · Mac cleanup not confirmed". Avoid per-note live-region chatter, use screen reader announcements for meaningful state changes only. Color plus words/shape; show pending discrete input immediately without fake note-on feedback.

## 3. Usable capacity and latency policy

Keep one foreground performance workspace with user-selected primary surface and optional existing pinned controls. Capacity applies to potential active streams, not widget count: two fingers in one drum stream do not reserve two sessions; piano sustain shares piano; Air Drums shares acceleration; pinned representations share canonical controller. Count pending request, armed-but-no-sample and release-pending conservatively as occupied until host confirms release or socket is retired; never reclaim remote capacity based solely on local reset.

Host policy must protect local instruments and bound per-peer reservations within 16 router sessions and four peers. PERF2 owns exact numbers, scheduling/reservation alternative and verification; this document neither raises caps nor proposes a fixed reservation quota. Until integration, report capacity as unknown; not "2/4 devices free". If a trusted policy provides remaining eligible combinations, show only allowed additional surfaces and a plain explanation. Client checks cannot replace host enforcement. Never silently disable another instrument, steal another peer's capacity or preempt local owners to enable a new stream. Host race/denial semantics must be documented and exercised by QA/PERF before showing precise capacity.

Use measured local ACK intervals only as diagnostics for frames already exchanged, with sample count and freshness; no synthetic RTT probe in performance or during active ownership, no promise from last sample, no fabricated signal-strength bars or thresholds. If no samples, "Latency not measured"; optional idle diagnostics "Recent ACK RTT: ... (n=..., last ... ago)"; not input-to-MIDI latency. A slow connection is not synonymous with resource exhaustion. User-facing overload state driven by actual scheduler/host decision, not invented numeric boundaries.

| Condition | User experience | Required behavior |
|---|---|---|
| Ready, additional stream unverified/unavailable | "Additional instrument unavailable for this session. Release another instrument to try." | refuse before activation; do not transmit or request permission; no current owners changed |
| Host explicitly refuses admission under a reviewed contract | "Mac capacity unavailable. Try fewer active instruments or ask Mac operator." | preserve existing owners only if host explicitly guarantees safe nonfatal refusal; otherwise close |
| Waiting for ACK within deadline | "Sending" or "Release pending" | no extra frame; no optimistic ACK; no UI-triggered repeated sends |
| Risk of missed deadline or queue saturation | "Connection busy — not accepting new inputs" if scheduler can safely finish existing ownership | freeze new onsets, preserve ordered edges/releases; no prolonged degraded mode; if uncertain close |
| Stale/overflow/missing ACK/rate fault | "Performance interrupted. Some inputs may not have reached the Mac." | fail closed with existing deadlines; clear queued input, no retry; request fresh invitation |
| Unspecified socket close | "Disconnected. Mac cleanup not confirmed." | no guessed capacity/latency/auth cause; reconnect manually |

Do not add preflight traffic, telemetry, a new overload packet or a special privileged control to work around one ACK lane. Future capacity fields are a coordinator/QA protocol decision; keep v7 exact schema and 256-byte message bound. If mapping details hidden, never infer capacity from target fan-out; host accounts for routes and resources.

## 4. Edge integrity and release

PERF-02 is a correctness gate, not an acceptable UX trade-off. XY down/up must survive another pending ACK as ordered bounded onset and release or produce explicit interruption and disconnect; never emit release-only and claim a played gesture. Do not replay stale onsets after release, emergency stop or reconnect. Continuous samples can be coalesced to latest fresh value only without losing gate transitions (including mapped note/sustain transitions); if mapping semantics are undisclosed or an edge cannot be classified safely, preserve it or fail closed. PERF2 owns queue representation and scheduler; UX requires behavior, not implementation. Don't generate velocity/pressure, retry a note or fake sound to mask loss.

The persistent Release action is always accessible and applies to this peer only. On tap, synchronously block new input, invalidate permission epochs, freeze hitboxes, clear obsolete non-release work, retain pending-frame knowledge and send valid per-stream release/zero snapshots in the same ACK lane. If an arm is pending and subsequently accepted, release it; don't send an unarmed motion release. If a down frame may have reached the Mac, release even when desired state is already zero. If prior onsets are unsent at emergency release, discard and disclose canceled input, never send them just to preserve an ordinary tap. Do not wait on a modal or depend on navigation for cleanup. A normal per-surface stop does not reset other owners. If all applicable release ACKs arrive, show "Release accepted by Mac" (not actual output confirmation), all controls Off and no auto-rearm.

Preserve 150ms oldest discrete edge, 220ms per-frame ACK, 350ms independent host stream timeout, 100ms host receipt freshness, 90 frames/s, 2s idle timeout and one outstanding frame. Existing 25ms tick/50ms eligibility is not a guaranteed cadence; do not relax deadlines. The earlier <=350ms aggregate global-release design budget remains a conservative upper bound from user intent, not a verified end-to-end guarantee; earlier per-frame/edge/watchdog constraints win. If no reliable release path remains or deadline cannot be met, immediately close; explicit Disconnect always closes without waiting. Host cleanup/neutral values depend on native router and output ledger; no peer-wide CC123, no global panic, no zero-value assumption. If audible stuck output persists, instruct user to use existing Mac-side stop/release controls; browser cannot certify cleanup.

On pointercancel/lost capture/key blur release the respective owner; multi-touch reference counting preserves other owners. Window blur, pagehide, hidden document, lock/background, network failure: close, cancel timers/permissions/listeners, drop snapshots and aliases/private metadata, no auto-reconnect. A late permission callback or old socket ACK never reactivates input. On reconnect new invitation, strict manifest and optional mapping sync, all controls Off; keep only nonsensitive layout preferences. Never restore prior holds, latches, consent-derived labels or stale queued events.

## 5. Partial mappings and navigation

Play lists only mapped surfaces; a mapped-but-currently-ineligible item is visible with concise reason and inactive handler. Unmapped surface never occupies a performance tab. Setup explains disabled items and capacity policy without offering unmapped controls. No automatic surface change on refusal or close; keep harmless layout choice but remove private mapping and input state; require fresh explicit activation. First mapped eligible surface can be selected visually, not armed.

- XY: one-axis or contact-only layout only if wire semantics verified; mapped axes/contact labels only. A partial mapping is not proof that other axes can be sent as a different protocol. QA-02 must pass before direct touch handler enabled.
- Piano: upper-only mapping selects valid window; sustain-only shows standalone sustain; never empty keyboard. Preserve geometry, disable unmapped keys and default scale overlay when actual pitches/fan-out unknown or custom. No label like "C4" if unverified.
- Drums/pedals: only mapped pads visible, unmapped pedals disabled or omitted; logical names "Pad 1", "Pedal 2" if disclosure off, actual target labels with consent, no assumed GM/FX. Fan-out shows target count if known; no invented active owner count.
- Motion: independent mapped streams; acceleration/Air Drums share capacity; no duplicate arm. Permission denied only disables that motion path and gives reason; no phantom active status.
- Pinned items do not create owners; while active, pin status and stop remain visible. Navigation away from active unpinned stream releases and awaits ACK before changing surface, or closes on failure. Cannot hide held contact/key/pad, pending arm or release. Setup/reorder/resize only with all outputs idle and no pending frame; do not unmount to simulate release. Orientation/zoom/layout relocation while held must preserve valid hitboxes or release/close.

Use 44 CSS px minimum for main hit targets, 48 preferred; persistent Release and Disconnect accessible at 320px width, large text/200% zoom, tablet and screen reader. No vibration/sound indication without evidence. Do not force fullscreen, lock orientation or request background permissions. Labels rendered as text, not HTML; QA-01 duplicate-key strictness applies before readiness, v8 later requires its own strict tests.

## 6. Implementation sequence and acceptance gates

A. Coordinator: QA-01/02 strict lexical parsing/source guard and idempotent release; independent QA2 exact-head verification. B. Coordinator + PERF2: ordered bounded XY edges, deadline-aware scheduling and explicit resource policy including local protection; preserve existing caps, verify exact candidate with negative tests. C. UI: implement truthful state, conservative availability and release/navigation with no new wire assumptions; single verified surfaces first. D. Integrate optional mapping/label sync from #81 only after strict parser and privacy gate; no speculative v8 fallback. E. Enable additional combinations only after candidate-specific evidence, then accessibility and actual Mac/iOS/Android/DAW acceptance. Each stage independently reviewable; no whole-release PASS from documentation or virtual-time metrics.

| ID | Test scenario | Required observation |
|---|---|---|
| O01 | Duplicate/escaped manifest field, malformed v1-v7 request | close before ready; no broadened capabilities; QA-01 negative regressions |
| O02 | drum-only source, direct v1 touch, harmless release | unmapped activation rejected host and browser; no allocated session; release semantics independently tested |
| O03 | partial mapped piano upper-only / sustain-only, hidden metadata | usable view, no invented note labels/scale or empty keyboard |
| O04 | fan-out with undisclosed targets, partial XY | logical labels only, no capacity or output inference |
| O05 | no approved capacity policy, 5ms last ACK | cannot infer permission for seven streams; verified single surface only or preview locked |
| O06 | pending arm plus second activation, same-stream pins | provisional capacity counted once, duplicate arm prevented |
| O07 | third peer, seven streams each, local input active | native cap/protection test; clear refusal or fail-close; no other/local owner stolen |
| O08 | 5/20/40 +/-15/60ms seven-stream workload on new exact candidate | record accepted/denied combinations, p50/p95/max gap, onset/release losses, closure; no unsupported activation advertised |
| O09 | 15ms edge bursts across drums/piano/pedals with jitter | every accepted ordinary edge delivered in order or explicit interruption/close; no silent loss; track attempted not unattempted edges |
| O10 | piano ACK pending, XY down at +5ms/up at +15ms | ordered onset+release within deadline or explicit canceled/interrupted + close; never release-only success |
| O11 | delayed/missing ACK, stale edge, queue full | no new onset after terminal fault, close within existing limits, no unverified cleanup claim |
| O12 | release while press/arm pending; all seven release if supported | send necessary release after ACK or close before budget; no unarmed release; no replay; report last ACK separately from host receipt |
| O13 | shared target held by local/other peer | release own contributors only; display no host-wide note-off claim; native commands checked |
| O14 | tab switch with held key, pinned pedal, resize/orientation | no hidden owners; stop remains accessible or release/close; no new arm |
| O15 | pointercancel, lost capture, keyboard blur; two fingers same pad | only appropriate owner released; final owner triggers release |
| O16 | pagehide/window blur/network loss, late permission and ACK | close, clear private data, no resurrection; fresh invitation only |
| O17 | reconnect with changed mapping and consent | clean staged manifest, no cached labels/activation, preserve visual preferences only |
| O18 | small screen/200% zoom/screen reader, pending release | always reachable emergency actions, truthful accessible statuses, no focus traps |
| O19 | source guard and release verified but scheduler/capacity unresolved | QA2 limited PASS not promotion; overload gate remains HOLD |
| O20 | host disconnect while note sounds, physical DAW/neutral ledger | native cleanup evidence independent from model; browser status remains unconfirmed without explicit feedback |

Reproduction of source PERF evidence: in isolated #82 checkout, extract frozen page via git show and run node studio/scripts/remote-stress/stress.cjs /tmp/r9-frozen-page.swift (expected exit 1 on frozen source per author). UX2 inspected pinned JSON and reports; did not execute native/runtime suites or repeat V8 simulation. Use same harness with new exact candidate and native capacity/ownership tests plus browser VM focus/permission/ACK vectors; CI logs separate from independent execution. Record exact SHA and hardware/browser versions; no credentials or private machine data.

Verdict: design addendum COMPLETE; frozen strict-schema and performance gates FAIL per cited agents; QA2/PERF2 remediation evidence, implementation, native and physical acceptance HOLD. No merge/release/installation.
