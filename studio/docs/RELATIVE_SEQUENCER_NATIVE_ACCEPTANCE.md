# Relative + Sequencer native acceptance (R22 supplement)

Status: **NOT EXECUTED**. This is a source-reviewed acceptance procedure, not a claim of physical readiness. Baseline candidate #279 at af4f1a50a501f106490e7988e08b156b26841f89. Earlier Relative design documents describe earlier implementation snapshots; this supplement does not rewrite that historical record. Revalidate instructions against the exact candidate under test. #277 and #280 are independent follow-ups, not assumed included.

## Preconditions and evidence

Use a supported physical Mac, Trackpad/Magic Mouse and an isolated, disposable DAW project, with low monitoring/haptic levels. No feedback loop or production performance. Record commit SHA, built app identity, artifact and checksum, macOS/device models, DAW and plugin version, selected surface, axes, references, gain/smoothing, endpoint/channel routing, output mode and test timestamp. Confirm the candidate is actually installed by the authorized tester; never auto-install or activate from CI.

The outbound Helper endpoint is NoSpeaker Touch MIDI Out; NoSpeaker Haptic MIDI In is inbound. The sequencer endpoints are TIHULU Sequencer and TIHULU Tuned Sequencer MPE. Capture raw MIDI messages with source identity and monotonic timing where possible, alongside UI observations. A local successful CoreMIDI send is not receiver acknowledgement. Separate arm-transition cleanup from first accepted touch; independent sustain may have its own messages.

Use PASS only for executed observations satisfying the expectation; FAIL for a discrepancy; HOLD for blocked or incomplete evidence; NOT_RUN for an unexecuted trial. Record each physical surface and route independently. Never replace native or physical evidence with portable Swift results. Existing global capture Gates I/J remain in MAC_HARDWARE_ACCEPTANCE.md.

## Acceptance matrix

| ID | Case | Procedure | Expected and evidence | Status |
| --- | --- | --- | --- | --- |
| REL-01 | Baseline and explicit arm | Record Absolute output, stop conflicting shared-bridge instruments, select one surface, enable MIDI Out and one expressive axis, start Helper. Lift all contacts; explicitly enable Relative. | No silent mode switch. Arm-transition cleanup is recorded separately; first newly accepted touch anchors without a relative reference jump. | NOT_RUN |
| REL-02 | Preflight rejection | Individually try Both surfaces, MIDI Out disabled, no expressive axes, conflicting targets, selected-surface sustain without sharing, and automatic RPN with Relative pitch bend. | Each invalid configuration is refused with an actionable explanation; no new Relative owner or wire output. Existing valid mode is not silently reconfigured. | NOT_RUN |
| REL-03 | Manual references | Test X/Pitch Bend alone, then Y/CC and contact-size/CC independently, including reference endpoints and several gains. | X bounded to 0–16383; CC bounded to 0–127; default references 8192/0/127. No claim of DAW parameter feedback. Capture actual wire bytes. | NOT_RUN |
| REL-04 | Clutch and direction | Anchor near center, move both directions, lift, change starting position, repeat on each physical surface. | Changes are relative to each accepted anchor; new touch does not reuse previous displacement; no output beyond wire bounds. | NOT_RUN |
| REL-05 | Smoothing and stationary contact | Exercise 0, intermediate, and 250 ms smoothing with slow, fast, stationary and tiny movements. | Movement and status remain coherent; no repeated stale movement. Stationary status regression is tracked separately by #277; do not presume included in R22. | NOT_RUN |
| REL-06 | Wrong source and neutral | Arm only Trackpad; move/lift Magic Mouse while selected Trackpad is held, then reverse the devices. | Nonselected-source events do not supply selected-source neutral or rearm evidence. A genuine selected-source lift precedes a new anchor. | NOT_RUN |
| REL-07 | Disconnect and rearm | While active, disconnect selected surface or induce controlled source loss. Reconnect, observe state, then explicitly rearm if allowed. | Old source identity and stale queued contacts cannot resume movement; cleanup stays visible; no unexpected automatic output. | NOT_RUN |
| REL-08 | Sustain separation | Use independent sustain first; then deliberately enable pedal sharing in a disposable routing setup and exercise lift/Stop. | No cross-owner sustain release during ordinary scoped Relative transitions; any shared pedal behavior matches configured policy. Record CC64 and note ledger. | NOT_RUN |
| REL-09 | Stop and Absolute return | Move pitch/CC, use Stop Relative / Helper, inspect cleanup and then explicitly start Helper again for Absolute. | Relative is disarmed; no queued movement after Stop; Absolute requires explicit restart. Pitch bend neutralization follows ownership; CC7/11 may retain configured last values. | NOT_RUN |
| REL-10 | Cleanup failure and recovery | Using an existing controlled fault harness, fail an actual owned release; inspect scoped retry, Stop MIDI and Reconnect separately. | Pending cleanup remains visible; no new owner replaces an indebted owner. Retry releases only applicable obligations. If manual DAW recovery is required, follow reset/relaunch instructions. Unplug alone is not proof of send failure. | NOT_RUN |
| SEQ-01 | Note MIDI source | Route TIHULU Sequencer to a dedicated instrument. Run a short note pattern, including a repeated note and a rest. | Melody channel 1; correct note-on/off pairing, off-before-on when required, no stuck notes; capture actual receiver log. | NOT_RUN |
| SEQ-02 | Drum MIDI source | Route drum pattern to a dedicated receiving instrument; run, stop, repeat. | Drum channel 10, expected note mapping and owned releases; melody instrument remains unaffected when sources are separately routed. | NOT_RUN |
| SEQ-03 | Confirmed grid | Run supported live MIDI mode; inspect marker and transport state while comparing actual MIDI event capture. | Marker represents last confirmed transport step, not proof of sounding notes or receiver acknowledgement. Legacy/tuned paths may not have a confirmed position. | NOT_RUN |
| SEQ-04 | Snapshot editing | While a pattern is playing, change notes/drums; navigate away and back, then stop and start a new take. | Active take retains its snapshot; edits affect next take. Navigation alone does not stop the take; state and Stop remain discoverable. | NOT_RUN |
| SEQ-05 | Cross-panel scoped Stop | Start a note take, open Drum Sequencer and stop the active take; repeat in reverse. | Status identifies the active take and scoped Stop is available; unrelated owner releases are not emitted. | NOT_RUN |
| SEQ-06 | Output choices | Test haptic-only, MIDI-only and Both with low output level on a supported device. | MIDI-only does not claim haptic playback; haptic-only does not create unintended MIDI notes; Both alignment is experimental, not sample-accurate. Record the two paths separately. | NOT_RUN |
| SEQ-07 | Tuned MIDI | Select a supported microtonal scale, choose MIDI-only, use Play tuned MIDI, route TIHULU Tuned Sequencer MPE to a separate MPE receiver. | Per-note bend and note release are observed on the dedicated endpoint; no claim that ordinary Play Pattern is tuned. Invalid output combinations are refused. | NOT_RUN |
| SEQ-08 | Stop during rapid transitions | Exercise Stop at start, at loop boundary, during a rest, during held notes, then repeatedly attempt another start. | No stale take sends after cancellation; no stuck notes; pending cleanup blocks UI restart. Direct-controller start guard is a separate follow-up; test independently when included. | NOT_RUN |
| SEQ-09 | MIDI cleanup failure | Use controlled native fault harness to fail owned Note Off or selector cleanup. Observe status, Retry MIDI Stop, and recovery. | Failed obligations remain pending until successfully retried; no unrelated/global reset on scoped retry; never infer failure or receiver acknowledgement solely from cable state. | NOT_RUN |
| SEQ-10 | Timing and deadlines | Run existing unmodified native receiver fixtures and repeat actual Mac/DAW captures under idle and controlled UI load. | Keep current thresholds; log wake, timer, actor-resume, identity, send and receiver-completion durations when available. Do not waive late events or classify an unexplained failure as runner noise. | NOT_RUN |
| INT-01 | Separate receiver routing | Route NoSpeaker Touch MIDI Out and TIHULU Sequencer to different receiver tracks; sustain a sequencer note while using Relative. | Trackpad helper messages affect only its receiver path; scoped Stop does not release independent sequencer notes. Record actual source and channel for each message. | NOT_RUN |
| INT-02 | Shared receiver limitation | Only in an expendable DAW session with no MIDI feedback loop, deliberately route both sources to the same receiver/channel. | Record observed interactions; do not assert end-to-end isolation when receiver merges sources. Restore separate routing before other tests. | NOT_RUN |
| INT-03 | Global versus scoped recovery | Exercise scoped Helper Stop, scoped Sequencer Stop, then explicit Stop MIDI/Panic/true Reconnect in separate trials. | Scoped stops preserve unrelated owners; global actions follow documented cleanup scope and prevent stale work. Do not use global reset to mask scoped failure. | NOT_RUN |
| INT-04 | Repetition and evidence | Repeat successful start/move/stop and start/play/stop cycles, including device change, with exact build provenance. | All failures retained, no leaked owned notes or unresolved cleanup hidden by UI. Report trial counts, timestamps, raw MIDI evidence and reproduction steps. | NOT_RUN |

## Failure and timing record

Keep historical mandatory native playback failures #252 and #263, including #263 receiver lateSendCompletion 50,143,167 ns, wake 73,611,125 ns, timer 70,525,416 ns, actor resume 3,085,709 ns, identity 841,500 ns and send 112,542 ns. These are historical diagnostic values, not new limits, and do not prove a root cause. Compare exact candidate, fixture, logs, actual receiver and clock domain before conclusions. Do not loosen deadlines, discard failed trials or label them flaky without evidence.

## Results template (one per trial)

- Case ID / variant / trial number:
- Tested commit / app checksum / environment:
- Configuration / endpoint / receiver / channel:
- Expected / observed:
- Raw log or trace / UI capture / monotonic interval:
- PASS, FAIL, HOLD or NOT_RUN:
- Cleanup state / remaining owned obligations:
- Reproduction and follow-up issue or PR:

## Source anchors on the baseline

- studio/Sources/NoSpeakerStudio/ContentView.swift: RelativeUIFragment and SequencerTakeStatus.
- studio/Sources/NoSpeakerStudio/StudioController.swift: explicit arm, status and scoped cleanup.
- studio/Sources/NoSpeakerCore/NativeHelperRelativeSession.swift: selected-source admission and release evidence.
- studio/Sources/NoSpeakerCore/NativeHelperRelativeManualSettings.swift: manual references.
- studio/Sources/NoSpeakerMac/MIDIHapticService.swift: local transport and release obligations.
- LIVE_SEQUENCER_MIDI.md and RELATIVE_CONTINUOUS_CONTROL.md: historical contracts and limitations.

Release gate: all required native and hardware cases must have actual evidence or explicit coordinator-reviewed scope limitations. Any unresolved mandatory failure or cleanup debt remains blocking. No stable release or hardware PASS is implied by this document.
