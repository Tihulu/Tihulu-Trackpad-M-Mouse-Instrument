# R9 acceptance matrix — integrated candidate

Production code baseline: PR #102, `15cd1ebf8114a46a49da3fd12def349c5890dbe7`. No stable modification, no release approval. Evidence-only follow-up adds host maximum metadata regression; it does not execute the physical acceptance cases.

## Automated evidence on exact #102

- Browser callback replay: 61/61 with V8 and lightweight Node shims; full native CI pending.
- Adapted v8 withheld handshake stress replay: 159/192 representative experimental scenarios, 14/14 lifecycle checks, 210/210 conservative profile/mask pairs pass both hold and burst (420 workloads). Explicit Setup -> experimental -> Play navigation used. Experimental supported mask counts by profile: 5 ms 127, 20 ms 127, 20 +/- 10 ms 126, 40 ms 60, 40 +/- 15 ms 60, 60 ms 35. Simplified host model only.
- Maximum metadata browser simulation: 64 destination rows and 49 labels, 57 pages, 60 ms ACK delay, 256-byte cap, atomic publication. Host-side full projection and dispatch regression newly authored here, not yet executed.
- #99 cumulative shared core and macOS build PASS; #100 and #101 shared core PASS, macOS queued. #102 CI pending at checkpoint.

## Physical and native acceptance (all HOLD)

Record exact commit/build, OS/version, phone/tablet OS and browser, Mac model, MIDI destination, network class, measured ACK RTT, failures, recovery, and MIDI monitor trace. Redact invitations, addresses, private labels and other identifying data before sharing. Do not install over stable; use a separate candidate build and a disposable DAW session, initially MIDI OFF.

| ID | Test | Required result |
|---|---|---|
| P01 | Candidate build/launch, stable rollback | Separate install and removal; stable settings unchanged |
| P02 | TLS loopback, LAN certificate, wrong origin/key | Correct connection only; wrong trust/origin/key rejected; no bypass |
| P03 | Phone and tablet, source-specific consent combinations | Withheld / destinations / destinations+labels correct; no other source leakage; cancel/reissue resets |
| P04 | Maximum metadata and interrupted page sequence | Complete valid snapshot only; timeout/invalid response closes; no active input during sync |
| P05 | XY fast taps and multitouch cancellation | Correct ordered onset/release; no ghost note on cancel; no replay after reconnect |
| P06 | Piano, drums, pedals, tilt, acceleration, rotation | Expected mapped commands only; independent release; permission denial and stale sensors safe |
| P07 | Custom labels, remapped notes, partial mapping | Truthful labels, scale disabled for custom pitch; missing controls inaccessible; no truncation of identity |
| P08 | Conservative simultaneous workloads | Every claimed combination passes on actual tested device/network; measure ACK and MIDI separately |
| P09 | Experimental overload and missing ACK | Explicit refusal or scoped fail-close; never silently imply successful output; no deadline extension |
| P10 | Release my controls / navigation | Pending release gates transitions; unsent edges canceled; no auto-rearm; disconnect on failure |
| P11 | Multiple peers and five local sources | Resource limits enforced, denied peer does not evict active peers or local sessions, shared ownership preserved |
| P12 | MIDI sink failure, sleep, background, rotation, network loss | Host cleanup and ledger neutral retry verified in MIDI monitor; no stuck note or sustain |
| P13 | Small phone, tablet, accessibility | All controls reachable, persistent release usable, no misleading status, no unexpected page movement |
| P14 | Actual performance and reliability | Record onset/release timing and dropped events with a MIDI monitor; ACK RTT is not audio latency |

## Decision
Automated evidence supports further isolated candidate testing. Independent review, full current-head native CI, real network/permission/viewport and physical MIDI acceptance are required before promotion. Experimental high-load failures are known; conservative simulated success is not a physical guarantee. No merge, release or stable replacement authorized by this document.
