# Native MIDI acceptance evidence — 2026-11-25

Status: HOLD (no live CLI output, no release, no hardware acceptance).

| Candidate run | Outcome | Evidence |
| --- | --- | --- |
| [45701647993](https://github.com/Tihulu/Tihulu-Trackpad-M-Mouse-Instrument/actions/runs/45701647993) | FAIL | `nativePlaybackReceiverVerifiesNoteGateAndCancellation`: receiver gate observed but expected finished state not returned. |
| [45702128574](https://github.com/Tihulu/Tihulu-Trackpad-M-Mouse-Instrument/actions/runs/45702128574) | PASS | Earlier six isolated fixtures, including receiver timing, completed. Does not certify the expanded inventory. |
| [45702527583](https://github.com/Tihulu/Tihulu-Trackpad-M-Mouse-Instrument/actions/runs/45702527583) | FAIL | `nativePlaybackRejectsChangedAndRestoredSourceIdentity`: CoreMIDI client creation returned -304. |
| [45702829290](https://github.com/Tihulu/Tihulu-Trackpad-M-Mouse-Instrument/actions/runs/45702829290) | FAIL | Expanded 13-fixture loop: 11 passed, two failed. `nativePlaybackUsesIsolatedSourceAndClosesIt` reported faulted instead of finished; `nativePlaybackCloseRetiresTerminalStateAfterIdentityLoss` failed at client creation with -304. Receiver timing and prepared-session fixture passed. |
| [45703789700](https://github.com/Tihulu/Tihulu-Trackpad-M-Mouse-Instrument/actions/runs/45703789700) | Core PASS, macOS pending at inspection | Static inventory verified 14 declared and individually scheduled fixtures. |

The numeric client error is observed evidence, not an established infrastructure root cause. The prior failure is not erased by a later pass. The failed state in the observer/playback fixture now includes the same fault reason, event lateness, identity query and send-duration measurements as the other timing fixtures. Keep the 50 ms event budget intact; no automatic retry that converts a failed fixture to PASS.

Gate: on an exact candidate, all portable tests, the mandatory complete native fixture inventory, native CLI boundary tests, bundle/preview checks, and separate physical acceptance must be tracked independently. Retain failed-run evidence. A passing virtual MIDI test is not proof that a DAW or physical controller works. Do not expose live CLI MIDI until the native lifecycle and recovery semantics are accepted.

## Follow-up experiment

Runs 45703200935 (12/13), 45703789700 (13/14), and 45704230294 (13/14) failed with -304 during client creation, in different isolated fixtures. Their other timing and identity fixtures passed. Apple's MIDIClientDispose documentation states that MIDIServer may exit when the last client is disposed: https://developer.apple.com/documentation/coremidi/midiclientdispose%28_%3A%29?changes=_5&language=objc . A third-party CoreMusic troubleshooting note reports similar -2/-304 failures: https://shakfu.github.io/coremusic/tutorials/midi_basics/ . This is a hypothesis, not a confirmed root cause on our runners.

The new CI-only experiment holds one endpoint-free CoreMIDI client alive for the entire isolated fixture loop, leaving each test in a fresh process and retaining all original assertions and deadlines. It explicitly requires CI and fixture opt-in, verifies readiness and liveness, and terminates its own helper at step exit. No device I/O, daemon restart, retry or status override. Compare full results on exact new candidate(s) before drawing conclusions.
