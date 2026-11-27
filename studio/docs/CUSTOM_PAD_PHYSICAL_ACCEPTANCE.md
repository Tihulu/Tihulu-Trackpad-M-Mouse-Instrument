# Custom Pad physical acceptance (experimental)

Status: HOLD until exact candidate CI and independent physical/DAW evidence are recorded. A passing build or injected sink does not establish private multitouch callback semantics, sustained-contact cadence or MIDI receiver behavior.

## Setup

Use an explicitly approved candidate on a physical Mac. Record commit, app build, macOS version, device model/type, orientation, DAW/version and receiver routing. Do not replace stable or publish an installer as part of this procedure. Keep a manual DAW stop/reset available. Test Trackpad and Magic Mouse separately. Do not route multiple TIHULU sources to one receiver for these tests.

## Input-only evidence (no MIDI)

In Instrument Builder > Custom Pad performance, choose the surface and run the 20-second input diagnostic. No layout is necessary. Existing performances must be stopped. Perform each run separately:

1. Idle, touch, hold still for five seconds, release; wait.
2. Two simultaneous contacts; stagger lifts; move across pad boundaries.
3. Repeated short touches and normal transitions, then rest.
4. For Magic Mouse, repeat using the other orientation.
5. Disconnect the tested external device during the probe where safe.

Copy Native input evidence after each run. Record the intended gesture and its observed outcome beside the report. The report stores aggregate state counts and relative inter-frame gaps, not contact coordinates, device IDs or key events. A trailing occupied gap is a lower bound, not proof of continued physical contact. An invalid/incomplete frame is not a neutral handshake. A quiet idle device does not prove disconnection. Do not infer a raw state code's meaning from frequency alone; correlate isolated gestures, repeat and independently inspect if necessary. No automatic relaxation of the 150 ms occupied-frame rule is permitted.

## Dedicated MIDI acceptance

Only after input evidence is understood, explicitly arm a compatible draft. Select the exact dedicated virtual source in the receiver (not All Inputs); disable unintended MIDI thru/feedback. Lift all fingers and confirm the UI reports physical lift. Use a MIDI monitor or DAW event log alongside audible playback.

| Case | Required evidence |
| --- | --- |
| Initial held finger | No onset until a genuine fresh lift; no readiness timeout beyond 10 s under responsive UI |
| Five-second stationary hold | One note-on and one note-off at lift, no retriggers or premature release; fresh physical frame cadence demonstrated |
| Overlapping note/chord owners | Shared note remains until last owner releases |
| Sustain | CC64 on before dependent onset; note-off before final CC64 off; no stuck sound |
| XY, bend, CC | Correct destination and range; scoped neutral on release |
| Idle then new touch | No false attack during idle; new touch sounds only on a fresh valid snapshot |
| Lost contact stream | Retired session, scoped cleanup, no automatic resume |
| Escape with cursor free | Dedicated performance stops, no pointer capture, foreground app receives Escape |
| Event tap interruption / permission loss | Live admission revoked and explicit restart required |
| Disconnect/reconnect | No old frames or notes after retirement; explicit fresh arm |
| Failed cleanup | Debt remains visible; explicit retry on original owned endpoint; identity loss requires manual DAW reset/relaunch |
| Legacy regression | Ordinary Touch Instrument, MIDI Helper, capture and sequencer retain prior behavior |

Capture actual receiver message counts/timing, stop reason, input evidence and remaining cleanup status. Copy the Local MIDI timing evidence after stopping and after any explicit recovery. Its maximum host-entry frame age, identity-query time and send time are separate observations, not additive latency or a DAW receipt. Send attempts include cleanup and failed sends. The host retains only the most recently closed timing record, not the endpoint. Save the report before starting another test. If a native identity collision occurs, both records are quarantined; do not attempt to reuse or dispose ambiguous handles. Reset the receiving DAW and relaunch before further trials. For an injected failure use a controlled test backend, not a destructive change to CoreMIDI. Local API success is not remote audible acknowledgement. Main actor watchdog scheduling is not a real-time cleanup guarantee.

## Acceptance record

For each case record PASS / FAIL / NOT RUN, candidate SHA, setup, expected vs observed outcome, sanitized log reference and reviewer. A physical test that cannot be performed is NOT RUN. Any stuck note, unexpected onset, unknown state transition, failed cleanup or unresolved exact-head CI keeps release on HOLD.

## Known native playback timing failure (CI, not physical acceptance)

Run 45912476502, first attempt, commit 7ccd744d: `nativePlaybackUsesIsolatedSourceAndClosesIt` faulted with `lateEvent`. Observed maxima: event lateness 557986166 ns, identity query 272071584 ns, native send 59375 ns, wake lateness 357496958 ns. Maxima need not come from the same event. Run 45912524614 (cf64feb8) passed all four platforms, but that does not resolve the first failure. The failed macOS job was explicitly rerun; retain both attempts. Compare receiver timing, scheduler wake and endpoint identity latency before changing production behavior. Do not increase deadline limits or waive the fixture. The Custom Pad timing report is a separate observation tool, not a fix for legacy playback scheduling.

### Timing-path changes awaiting exact-head acceptance

Playback skips the redundant polling identity query when a scheduled edge is due or within the final 20 ms wake interval. Initial/terminal validation, per-onset authorization, per-off identity checks and the 50 ms playback lateness limit remain. This reduces avoidable IPC but cannot bound macOS scheduler or CoreMIDI query stalls. Custom Pad now performs its pure projection before the per-send identity checks; final publication still validates identity and freshness, even for unchanged frames. The 150 ms freshness limit remains. Capture the FIFO peak and first fault reason along with timing evidence. An unordered producer frame revokes delivery for a previously drained batch, subject to a native call already in progress. Verify with repeated exact-head CI and physical traces; never classify the original failure as fixed based only on the code change.

### Frozen performance visualization and UI acceptance

Select a device using the visible Custom Pad surface picker even with the offline designer collapsed. Choose Trackpad or Magic Mouse and create or load a compatible draft. Arm and confirm the read-only map describes the chosen surface and channel. After physical neutral, touch a note, chord, drum, sustain or continuous pad and compare the active logical indicator with the receiving MIDI trace. Multiple contacts sharing one pad produce one indicator; overlapping note ownership across pads can illuminate both. A logical indicator is not a DAW receipt or a guarantee of acoustic sound, and brief states may not be visible at UI refresh cadence. Edit the separate draft or switch the editor's selected surface while armed: the frozen map, MIDI source and channel must not change. A stopped, retired, or quarantined session must not retain active indicators even if MIDI cleanup debt remains; recovery status must still be visible. Verify VoiceOver reads active/inactive separately from color, labels remain legible, and diagnostic-only operation does not display active MIDI pads. A failure should distinguish native FIFO fault, identity loss, expired/invalid input, admission revocation or failed local send. Record exact candidate and actual observed outcome, including any false highlighting or missed stops.

## Independent multi-surface coordinator (portable, not exposed as native performance yet)

The group coordinator owns an exclusive host, freezes one plan per surface kind, refuses duplicate kinds, opens each dedicated source transactionally and keeps a separate receipt/sequence/ledger per member. A device can play after its own neutral handshake; all members must confirm neutral within 10 seconds of completed group arm. Any detected member fault, clock regression or loss of group admission stops the entire group, retains unconfirmed cleanup and requires explicit recovery/rearm. A previous run token cannot dispatch to a new group. Distinct source ports must be routed independently by the DAW; downstream merging on the same channel/note can still interfere. The native touch service now supports atomically installing up to two distinct per-kind inboxes and each inbox has a one-shot begin boundary. This is infrastructure only; the single-device Studio UI remains the live path. Native group admission, physical inventory changes, input pump, emergency stop, fairness under simultaneous traffic, port routing and UI all need separate integration and physical tests. The 50/150 ms existing limits are unchanged.
### Native two-device integration candidate

The Studio performance panel now includes an explicit experimental two-device arm with a frozen Trackpad draft, frozen Magic Mouse draft and independent channels (defaults 1 and 2). The shared native host excludes single-pad entry points while a group is live or recovering. The native input group drains at most two bounded 64-frame queues per batch in original receipt order, with deterministic ties and a group-wide fault fence before/after delivery. This is not a hard real-time scheduler; a blocking native call or actor delay may still retire output. Arm both only after both physical sources and Escape monitoring are available; changing a draft while armed cannot modify either frozen layout. Test missing device, partial port creation, both initial lifts, repeated identical contact IDs across devices, overlapping pitches on separately routed receiver tracks, independent releases, simultaneous dense traffic, permission loss, device removal, FIFO fault, Escape, stop, recovery, stale generation, and return to the single-device path. Collect the per-surface input evidence and last observed local MIDI timing. Group timing snapshots are sampled before close and are not a complete post-cleanup record. Never infer receiver confirmation from indicators. The original playback fixture retry passed on the unchanged 29-commit tree (run 45912476502); retain original failure as evidence and repeat timing trials on the actual optimized candidate. Physical and exact-head macOS acceptance remain HOLD.

### Registration identity and late peer fences

Each driver monitoring registration now generates a distinct ephemeral UUID per admitted physical kind. Studio binds the expected UUID before arming; callbacks from a different or missing registration cannot serve as a neutral handshake or renew MIDI admission. Single, group and diagnostic pumps compare current registration tokens before consumption. These UUIDs are process-local, are not hardware serials and are not included in evidence reports. Native enumeration refuses duplicate IDs instead of collapsing them into a set, and existing multiple-external-surface refusal remains. Test a monitoring restart, replug, duplicate/ambiguous inventory, a stale callback and both normal surfaces. A callback first entering the private bridge after a re-registration with a reused raw pointer cannot be proven to belong to the old registration; physical API lifetime semantics still require acceptance. The group also checks other members' local cadence after potentially slow MIDI identity queries and before sending; a native call already in flight cannot be atomically revoked. Both final per-source timing records now survive stop and explicit recovery; use the final report instead of the earlier pre-close snapshot. No real hardware or DAW run has been performed.

### Independent draft channel and preset acceptance

Studio now shares one draft melodic channel per surface between the single and group arm paths; save/load explicitly includes that channel. Legacy layout-only storage is readable with visible defaults (Trackpad channel 1, Magic Mouse channel 2), without silently saving or arming. Invalid, orphan or duplicate channel records must leave the original data untouched. Six starter drafts are available only when that surface has no current draft: chromatic notes, GM drums, major/minor chords, sustain, pitch bend and modulation/expression XY. These are editable Standard MIDI maps, not synthesizer patches. Drum destinations remain on GM channel 10 and helper destinations retain the explicitly assigned channel, even after changing the melodic channel. Verify switching between devices preserves draft channel values, saving/loading both surfaces independently restores the chosen channels, old libraries remain readable, confirmation rejects changed drafts/channels, active frozen layouts remain unchanged, and new starter creation never overwrites a draft. The routing advisory reports actual overlapping channels and identical destinations if the DAW merges ports; it is not DAW routing detection. Shared channels can affect both instruments even without identical note/CC targets. Verify different-source routing, merged-channel sustain interference, and both GM drum sources on channel 10. Current bridge registration comparison is also checked in live admission without a private API query; it cannot make an already-started native send atomic.

### Pair profile transactions and playback regression

The two-device panel now supports explicit Save both drafts and Load saved pair. A saved pair is derived from the two independently stored layouts, not a new independent preset library. Both layouts and channels are captured for confirmation, along with the stored bytes; a changed draft/channel or library aborts the operation. A load replaces both current drafts only, including unsaved edits after confirmation; it never arms MIDI. Save preserves unrelated Touch Bar/phone/tablet layouts and channels. Repeated identical saves preserve record order and equality; legacy implicit channel defaults remain distinguishable from explicitly saved values. Verify pair controls even with designer collapsed, cancellation, corrupt storage, incomplete pair, changed channel during confirmation, unchanged save disabling, and single/group arm using the restored values. Older builds may discard new channel records if they rewrite the same storage; do not use a downgrade as a profile backup.

The 44-commit macOS fixture run 45914701981 failed nativePlaybackReceiverVerifiesNoteGateAndCancellation with lateEvent, observed event lateness 53,034,917 ns, wake lateness 53,030,792 ns, timer lateness 52,648,875 ns, maximum actor-resume delay 2,021,208 ns, maximum identity query 454,333 ns and native send 83,791 ns. These are maxima and not additive measurements of one event. The 50 ms event limit remains unchanged. The exact failed job was requested for rerun, and this is not evidence of a resolved scheduling problem or physical latency. Preserve the initial failure and both results.

### Staged editor decision gate

Unapplied pad geometry/label edits and an enabled assignment-replacement toggle require an explicit Apply or Discard before switching surfaces or pads, adding/removing pads, saving/loading/resetting drafts, or arming a single/group performance. The warning and discard action remain visible with the designer collapsed. Selecting the same pad does not reset its fields. New selection initializes every assignment field, not values inherited from a previous pad. Stop, Escape, diagnostic stop and cleanup recovery remain available. Verify both picker and map navigation, same pad ID across devices, invalid edits, save/load and group arm while a field is staged, collapsed designer and stopping live output while editing. This is a source candidate; native UI behavior still needs exact-head compilation and interactive acceptance.

### Exact geometry and assignment editor

Offline pad edits report the exact rejected field or overlapping pad before Apply, with the existing immutable layout validation still authoritative. Coordinates span the complete 0...9999 origin and 1...10000 size domain; fine step is one unit (0.01% of the surface). Note, drum and tuning degree editors have independent values and valid domains. Test a one-unit edge pad, thirds and other non-round preset boundaries, out-of-bounds sizes, overlap, multi-byte labels, Touch Bar height, switching between negative tuning degree and standard MIDI/drum assignments, failed Apply retaining the original, and stop/recovery while editing. No live retuning or expanded native capability is introduced.

Native compilation checkpoint: f3365a54 and 5d1731e6 both failed SwiftUI type checking at the draft map Button expression (macOS jobs 140262213930 and 140262505462). Core, Android and iOS passed. Split the designer, draft map button, frozen map cell, assignment fields and edit actions into typed helper expressions, retaining staged-edit and Stop/Escape rules. This is a compiler-fix candidate, not a claim of passing native compilation or interactive acceptance.

Exact-head 1c23577d macOS job 140274920535 passed native compilation, unit tests, isolated MIDI fixtures, standalone SDK and experimental compile gates. Packaging failed because build-app.sh lost executable mode during the earlier branding edit; verify-preview-dmg.sh had the same mode regression. Restore both original tracked modes without changing their contents, and guard entrypoint modes in portable and native CI. Full package acceptance still requires the successor run.
