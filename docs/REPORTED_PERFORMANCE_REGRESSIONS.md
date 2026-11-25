# Reported performance regressions — acceptance ledger

Audit 25 November 2026; candidate base #161 c35bb0556c00cae8be943c5adf5d474f0a6c04be. User-reported symptoms are not closed merely because a unit test passes. Linux run 45588262542 executed 459 successful core tests before the English-source gate failed. Native/physical acceptance is separate.

| Reported symptom | Source / automated evidence | Required physical acceptance |
| --- | --- | --- |
| Global Capture shortcut matches but cursor is not captured (22 event-tap timeouts, eight matches) | #20/#22; current StudioController capture generation fence, 500 ms health check, fail-open, Capture Now, Escape. Static review only this round. | Arm with permissions, custom modifier orders, app switching, all modes, repeated timeouts, verify cursor release without stopping MIDI/haptics. |
| Logic audio/MIDI dropout when phone microphone / Continuity changes | #22 persistent CoreMIDI client, #139 CI 45524857930 success; current start/stop keeps endpoints across soft stop. No reproduction of audio route transition. | Real Logic session with sustained notes, microphone/Continuity route changes and fast playing; capture audio device state and MIDI monitor separately. |
| Helper sustain-only with external MIDI keyboard raises velocity/volume | Current handleMIDIHelperStates gate returns before expressive controls; existing helper gain release and no-effects tests passed in 459-test run. New combined production-policy regression authored. | Hold keyboard notes at fixed velocity/CC7/CC11; toggle helper sustain; inspect MIDI monitor for CC64 only and compare audible gain. |
| Magic Mouse Tap Toggle contact-size sensitivity and Trackpad click-pressure | #133 exact CI 45519664560 success; threshold invalid-value tests passed. | Tap below/above threshold, drag, lift, repeat; both Touch Instrument and Helper; Hold/Click behavior. |
| Touch/Helper independent sustain and changing effects | #148 exact CI 45531550444 success; same-channel owners, split-channel sustain and rearm tests passed. | Different channels, overlapping pedals, remap effects with pedal held, release one owner at a time. |
| Trackpad/Magic Mouse multi-touch and fretless | #137 CI 45522523555 success; explicit Standard/MPE distinction. | Both surfaces, simultaneous fingers, MPE independent bends and note-offs, haptic-only behavior. |
| Drum multitouch in Trackpad mode; melody starved by drums | #146 CI 45528950198 success; simultaneous drum/mixed melody core tests passed on #161. | Rapid multi-finger strikes and simultaneous melody; physical vibration/latency, six-tone limit. |
| Fast playing / missing short attacks | #139/#140/#144/#159; ordered inbox 10,000 edges, held-priority and attack buffer tests passed in #161 core run. | Physical rapid taps, chords, high-load DAW, measure note on/off and actual sound timing. |
| Lid sensor unavailable, Touch Bar/Magic Mouse/Lid cannot control pitch/wah while playing | #55, current exclusive live-performance guards remain; lid normalization test passed. | Real supported lid hardware, Touch Bar availability, each source note/helper mapping, simultaneous combinations. Cross-engine group routing still open. |
| Xbox pedals, XY, multiple controllers and haptic combinations | #157-160 exact CI success verified previously; three-source mixer and pedal ownership tests passed in #161 core run. | Four devices, disconnect/reconnect, scoped stop, both MIDI/haptic, Logic effects and sustain. |
| Phone/tablet touch, gyro, LAN, camera and party jam | Core tests for remote timeout, admission, orientation, drum/piano, ownership and stale events passed in #161. | Multiple physical devices, latency/loss, permissions and camera tracking; native companions and group ports remain open. |
| Turkish voice choices and responsive synthesis | #149-151, cancellation and bounds tests passed on #161. | Installed voices/models, male/female availability and physical speech quality; no unsupported voice promises. |

## Acceptance rules
- Log exact commit, test and hardware/DAW version. PASS for automated evidence is not physical PASS.
- Keep legacy bugs in this ledger until physical reproduction and verification; add a negative regression for new findings where feasible.
- Separate MIDI event delivery, audio-device changes, physical haptic output, UI preview, and input permissions.
- Do not install over stable, merge, or release. Do not change safety deadlines, physical polyphony, or CI checks merely to obtain green.
- New group routing/assistant: test fixed port identity on rename, cross-group CC ownership, note/Helper layer, MPE independent ports, no-send setup, cleanup debt and safe panic. Do not imply GarageBand parity.
