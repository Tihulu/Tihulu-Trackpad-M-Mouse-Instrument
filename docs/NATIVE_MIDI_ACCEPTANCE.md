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
