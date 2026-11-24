# R5b — editable Air Drums presets and sensitivity

Eight General MIDI note presets on channel 10 (zero-based 9): kick, snare, closed/open hi-hat, low/high tom, crash, ride. Phone/tablet selection; append only, never silently replace or duplicate a mapped destination. Layered notes on one source deliberately trigger together; a single device is not a full independent drum kit. Different devices of the same source kind share mapping defaults, not detector state.

The existing archived route threshold and hysteresis now configure the host onset threshold and reset gap. Validation rejects unsupported strike destinations/sources, invalid detector settings and conflicting settings on a shared source. Route calibration/curve and velocity ceiling shape velocity. Presets use threshold 0.45, reset gap 0.25, velocity ceiling 127. Existing manually configured routes use their saved values. Quiet duration 80 ms and minimum retrigger interval 120 ms remain fixed. No archive schema migration or graph data loss. Browser explicitly warns that enabling acceleration may trigger mapped notes, and advises gentle movement. No new permissions.

Four tests cover presets, archive/graph round-trip, settings conflict/validation, and detector sensitivity. Host integration uses settings when arming acceleration. Physical acceptance and timing remain HOLD. Stable unchanged.
