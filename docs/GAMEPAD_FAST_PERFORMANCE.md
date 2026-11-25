# Native gamepad fast-performance candidate

Base #141 (a024327e21fa9d755701750aff08eabab2ffd37c). Existing macOS and shared core CI for that exact base passed.

Use GameController extended-profile value-change callbacks on the explicitly selected main queue, immediately invoking the same PhysicalPatchRuntime path as the watchdog. No per-edge Task. Initial real snapshot establishes neutral rearm; 20 ms polling remains for disconnect, heartbeat and fallback. A frozen adapter token and Studio run token fence callbacks; Stop removes installed handlers and restores the previous handler queue. No new MIDI owner state. Reference: Apple GameController valueChangedHandler and GCDevice.handlerQueue documentation. System-level callback coalescing, delayed main-queue work and short local haptic attacks still require hardware verification; this is not a guarantee of every physical press.

Map UX: load existing simple assignments on selection; accept MIDI numbers or named notes (including sharps/flats and negative octave); preserve calibration for retained unique destinations. Copy one slot's complete map to the other with optional common MIDI channel. Existing target requires explicit confirmation; other devices/source mappings remain unchanged. Mixed routes have a warning and remain editable in Advanced Routes. All operations validate full patch and original route cap.

Physical Builder command history: bounded pending 24 logical attempted commands, formatted and published only when the existing watchdog drains, including flush on stop/failure; MIDI and haptic calls retain original synchronous ordering. Simulation remains immediate. This is display batching only, not musical event batching.

Four new tests authored: named note bounds and duplicates, copy/retained calibration, 1,000 two-millisecond synthetic chord presses with duplicate polling snapshots, and 1,024 command-history equivalence. No claim of running them locally or physical DAW latency measurements. Require full CI and paired-controller rapid taps, rolls, simultaneous chord attacks, haptic-only/Both, loss/rebind, main queue overload, stop and panic. Existing stable application is untouched.
