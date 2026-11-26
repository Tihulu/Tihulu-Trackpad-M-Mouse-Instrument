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

Capture actual receiver message counts/timing, stop reason, input evidence and remaining cleanup status. For an injected failure use a controlled test backend, not a destructive change to CoreMIDI. Local API success is not remote audible acknowledgement. Main actor watchdog scheduling is not a real-time cleanup guarantee.

## Acceptance record

For each case record PASS / FAIL / NOT RUN, candidate SHA, setup, expected vs observed outcome, sanitized log reference and reviewer. A physical test that cannot be performed is NOT RUN. Any stuck note, unexpected onset, unknown state transition, failed cleanup or unresolved exact-head CI keeps release on HOLD.
