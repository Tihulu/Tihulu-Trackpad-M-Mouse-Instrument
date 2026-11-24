# R9-UX — authenticated mapping contract (proposal)

Status: DRAFT / design only; coordinator approval required before implementation. Frozen reference: `287560d4e522cf46b585e7212c4413ecce3c3d1b` (PR #80). No changes to v1–v7, production code or stable. Companion: REMOTE_R9_PERFORMANCE_UI.md.

## 1. Purpose and non-goals

The performer must know what a control actually maps to, including multiple destinations, instead of trusting default instrument names. The Mac is the single authority for the configured patch and route semantics. Browser input remains logical IDs and normalized values: no destination selection, patch mutation, MIDI injection, clock, source, routing priority or release override on the wire. This is a read-only snapshot, not a remote patch editor, DAW discovery service or live MIDI monitor.

Baseline: RemoteCapabilities.swift exposes v7 masks only; PhysicalPatchRuntime.swift:51–62 prevents configuration while sessions/peers exist; :151–180 derives capabilities from admitted source. SensorRouter.swift defines 64 mappings and 16 sessions, destinations with zero-based channel. InstrumentPatch.swift validates routes and excludes reserved CCs. PerformanceLayout.swift supports user labels, but its widget kinds are desktop layout preferences, not authorization for new mobile wire signals.

## 2. Admission, privacy and compatibility

- Retain invitation admission, exact Origin/TLS checks, one outstanding host response, existing replay/rate/freshness/idle checks and 256 UTF-8 byte limit. A v8 query is legal only after admission and successful v7 negotiation and while the peer is idle. No query changes ownership or extends an active stream's watchdog.
- A new host serves a constant mapping-extension support flag in its own same-origin browser page (not a URL parameter or v7 extra field); v7 stays exact schema. New page queries v8 only with this flag and valid v7 response; old host/page remains v7 behavior. New host accepts old v1–v7 clients unchanged. A new page without support uses logical names, explicitly marks mapping details unavailable, disables unverified pitch/GM overlays. No unrestricted legacy fallback or probing a host that would close on unknown v8. If advertised v8 returns malformed/timeout, close and require fresh invitation; do not silently downgrade.
- Explicit Mac-side per-invitation consent, default off, for destination detail; separate default-off consent for user-entered labels. Explain that anyone with that admitted device can see disclosed MIDI channels/notes/CCs and selected labels. Snapshot only the host-admitted phone OR tablet source. No patch/project/device names, route IDs, host identifiers, paths, endpoint names, credentials, other sources, calibration, velocities, priorities, curve or release settings. No telemetry, logs of payloads, storage, browser cache or query strings; clear memory on disconnect. Serve page with no-store. Revoke peer if consent withdrawn; no live policy change. Same-source multiple peers have separate admission/consent; do not reuse their metadata.
- Labels are optional display text only, never authority. Explicitly consented PerformanceWidget.label for an exact source/signal is eligible; empty omitted, XY label applies to x only, never implicitly to y. User can opt out and still play. Browser can use session-only aliases (never upload) with real destinations always available if disclosed.
- Pin immutable snapshot on first v8 query to configured patch + connection + consent. Existing configure guard means no patch changes with admitted peers; to edit, revoke remote owners, apply patch on Mac, issue new invitation, resync. No persistent revision or cross-connection caching needed. If implementation later permits live edits, this contract requires revocation before applying; do not serve mixed generations.

## 3. Proposed wire v8 (ASCII JSON, exact schema)

One request per page, common sequence space with v1–v7. Request:
```json
{"version":8,"sequence":2,"kind":"mapping","page":0}
```
Response (replaces accepted ACK only for this request):
```json
{"kind":"mapping","version":8,"sequence":2,"page":0,"pages":1,"total":2,"detail":true,"rows":[[9,0,9,36,1],[9,0,9,38,1]]}
```
Exact fields, integer values only (no bool coercion, fractions, negative zero or exponent notation); sequence 1..9007199254740991, echo pending request exactly. Page 0..7. Rows are [signalID, destinationKind, channel0, number, multiplicity]. Canonical compact ASCII JSON, no whitespace required on encoding, UTF-8 bytes measured on both ends before parse; reject duplicate object keys (including escaped equivalents), invalid UTF-8, unknown keys, trailing data, non-canonical number forms and excessive nesting. No compression. For v8 only, use bounded tokenization before ordinary decoding; JSON.parse/JSONSerialization alone do not detect duplicate keys. Binary response rejected by browser.

Signal IDs (fixed protocol registry, not enum ordinal):
| IDs | Logical signal |
|---|---|
| 0,1,2 | x,y,contact |
| 3,4,5 | tiltYaw,tiltPitch,tiltRoll |
| 6,7,8 | accelerationMagnitude,rotationMagnitude,airStrike |
| 9..16 | drumPad1..8 |
| 17..41 | pianoKey0..24 |
| 42 | pianoSustain |
| 43..48 | pedalExpression,Volume,Wah,Sustain,Switch1,Switch2 |

Destination kind 0 note (0..127), 1 CC (0..119 except 0,6,32,38,64,96,97,98,99,100,101), 2 pitch bend (number=0), 3 sustain (number=0, displayed CC64). Channel 0..15, display channel+1. Validate the per-signal kind restrictions of InstrumentPatch/RemoteDrumPads/RemotePiano/RemotePedalboard: airStrike/drums/piano keys note; pianoSustain/pedalSustain sustain; first 3 pedals CC or bend; switches CC; other signals follow valid generic patch destinations. Do not claim to validate omitted calibration/response values on client; host must derive only from an already validated configured patch. Source/route IDs never enter response.

Group equal (signal,kind,channel,number) tuples and count actual routes, preserving fan-out including duplicate-target routes without disclosing IDs. Sort lexicographically ascending by first four integer columns; no duplicates. Count 1..64; sum <=64 across all pages, total is number of grouped rows (0..64). Page size exactly 8 except last, pages=max(1,ceil(total/8)); page starts at 0 and advances exactly once per ACK (no repeats/skips); matching total/pages/detail on every response. Max 8 pages. With consent off return pages=1,total=0,detail=false,rows=[]; no count leak. With detail on, all mapped logical signals must appear; compare reconstructed v7 booleans and masks exactly, with acceleration=true if signal 6 OR airStrike (8) per runtime, airDrums iff 8. Any contradictory/missing mapping fails closed; unsupported signals are not silently mapped. A detail=true zero-row snapshot is valid only if v7 has no capability.

Worst-case width calculation (not necessarily semantically valid): seq 16 digits, page 7, pages 8, total 64, eight 16-byte rows like [48,1,15,119,64] plus envelope => 247 bytes in compact JSON. Encoder MUST enforce actual <=256; no truncation. Sequential page assembly in staging, capped at 64 rows; commit atomically only after all checks. No controls enabled during negotiation. No page traffic during performance; refresh only via disconnect/reinvite. Shared 90 frames/s cap, 100ms host receipt freshness, 2s peer idle limit, 350ms active stream timeout remain unchanged.

## 4. Optional consented custom labels

A second bounded phase follows successful mapping detail assembly; no labels if detail=false. Host advertises this sub-extension with a constant page-build flag, not by modifying v7 or mapping response. A supporting browser requests page zero, then exactly the next page; no parallel queries:
```json
{"version":8,"sequence":3,"kind":"mappingLabels","page":0}
```
```json
{"kind":"mappingLabels","version":8,"sequence":3,"page":0,"pages":1,"total":1,"rows":[[9,"S2ljaw"]]}
```
Rows [signalID, unpadded canonical base64url of UTF-8 label]; example Kick. One row per page, total 0..49, pages=max(1,total), no row on empty response. Strictly increasing IDs, only mapped signals, one per signal; exact envelope and sequence as above, page 0..48. Host sends empty page if no separate label consent; no hidden label count. Decode strictly, round-trip base64url, valid UTF-8, 1..64 bytes, no control/format/bidi override/zero-width characters; reject labels consisting only of whitespace. Host omits unsafe labels, never silently truncates. Browser rejects invalid encoding or text and uses textContent, never HTML/URLs. User-supplied names are untrusted even from host. Worst-case 86 ASCII base64url chars, one row plus the widest envelope is 199 bytes in compact JSON. Max 49 label requests only for fully labeled patch; throttle combined metadata requests to <=20/s, idle-only, one pending, per-request deadline <= existing 220ms ACK deadline, overall 10s budget; no relaxed server cap. If latency exceeds budget close, user can reconnect with labels disabled. Host may disable this optional phase at build level; no label query then. Prefer destination labels over custom names in detail view, show both when present. The separate phase avoids arbitrary strings in hot path and is not necessary for play.

## 5. Rendering semantics

Destination labels generated locally: note 60 = C4, octave=floor(note/12)-1, channel displayed one-based; e.g. Ch 10 · C2 (36), Ch 1 · CC74, Ch 2 · Pitch bend, Ch 3 · Sustain (CC64). MIDI channel 10 is not proof of General MIDI or drum sound; label names like Kick only if user explicitly provided, or explicitly labeled factory suggestion never as actual output. CC74 has no guaranteed filter mapping. Fan-out summary "2 targets" plus expandable full list; multiplicity >1 shows route count, not multiple notes emitted. Never infer active notes from metadata. Host calibration, arbitration and DAW decide sounding output. Unavailable metadata: "Pad 1 · mapping hidden" etc.; no invented MIDI destinations. Per-control local aliases must not obscure canonical logical identity or disclosed targets.

## 6. Protocol vectors and acceptance requirements

All are design vectors, not implemented runtime tests. Assume admitted idle peer, v7 drums=1, all other masks/flags zero unless stated.
| ID | Input | Required outcome |
|---|---|---|
| M01 | example mapping response above, seq=2 | accept; Pad 1 has two targets, Ch10 notes 36/38 |
| M02 | rows [[9,0,9,36,2]] with total=1 | one target, two routes |
| M03 | detail=false, total=0, pages=1, rows=[] | accept; logical labels only |
| M04 | same as M01 but signal 10, unmapped | reject/close |
| M05 | same as M01 but channel 16, CC64 kind=1, or note=128 | reject |
| M06 | [9,0,9,36,1] twice, unsorted, sum>64 | reject |
| M07 | total=9, pages=2, first page 7 rows | reject; expect 8 |
| M08 | page 1 before page 0, mismatched sequence, repeated page, changed total/detail | reject |
| M09 | duplicate kind, escaped duplicate key, extra source, boolean channel, 1e0, -0, oversized UTF-8 | reject before state commit |
| M10 | query before admission/v7 or while any stream active, old sequence or rate overflow | close; release peer owners, no metadata |
| M11 | phone patch note 36; tablet patch note 60; local route 72 | phone sees only 36; tablet only 60; never 72 |
| M12 | reconnect after patch/consent change | no old data or auto-arm; new snapshot |
| M13 | label example, malformed base64url, bidi override, unmapped signal | accept Kick only; invalid cases close |
| M14 | v7-only page/host, v8 host with old client, invalid advertised v8 | legacy path unchanged; no speculative v8 query; invalid advertised v8 closes |
| M15 | 64 valid grouped rows spread over 8 pages | all <=256, total/sum verified, publish only after final page |
| M16 | v7 acceleration true with only airStrike row, tilt mapped only yaw | accept matching aggregate flags; no phantom acceleration target |
| M17 | pitch bend or sustain with number !=0, switch mapped note | reject |
| M18 | user withdraws consent while paired | revoke, clear data and release; no metadata on old socket |

Implementation gates: Swift unit tests for snapshot derivation, source isolation, consent, pinned generation, bounds/strict decoder and expiry; Node VM tests for response staging, malformed packets, legacy paths and text-only rendering; transport tests for admission, no query during active streams, no ACK bypass. Independent QA + PERF review required. Physical Mac/iOS/Android/DAW acceptance remains HOLD. CI #80 run 45420260754 is baseline only (in progress when checked) (https://github.com/Tihulu/Tihulu-Trackpad-M-Mouse-Instrument/actions/runs/45420260754); no CI pass is claimed here.
