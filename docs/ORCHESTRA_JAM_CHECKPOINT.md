# Orchestra & Jam — first host ensemble presets

Load Chamber ensemble or Rhythm jam from Instrument Builder. Existing draft replacement confirmation remains in force. The templates use the existing host router and explicit MIDI output, not a second synth or network server.

Chamber: phone piano ch 1, tablet piano ch 2, camera expression on both channels, Trackpad single bass note with bend/expression ch 3. Rhythm: phone GM drums ch 10, tablet piano ch 2, camera expression/wah on ch 2, Trackpad bass ch 3. The bass note is a fixed-note expressive control, not a complete keyboard. Customize routes before starting. In the DAW assign each MIDI channel to its desired instrument; templates do not select DAW patches or send program changes.

Pair phone/tablet through the existing TLS invitation flow. Mapping details remain opt-in, source-scoped; musical labels do not grant producer/conductor/admin privileges. Camera conductor is local and only controls configured expression/wah. Test independent player releases, loss, and physical MIDI output. No shared tempo, conductor transport, audience role, permission expansion, or network protocol change yet.

## Host tempo checkpoint
The Builder exposes a visual beat indicator and separately opted-in MIDI Start/Clock/Stop on the TIHULU Ensemble Clock virtual source. BPM and meter are immutable while running. Clock uses 24 PPQN with absolute monotonic deadlines and fail-stop on missed pulses; no catch-up bursts. Stop, Panic and page exit stop clock without changing other source owners. Failed Stop delivery retains debt for retry. Timing precision, external DAW synchronization and hardware performance require real acceptance. This is not mobile clock synchronization or an audible metronome.
