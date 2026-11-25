# Air Dual Hand Performance — implementation contract (design, not runtime)

Research references: https://maru.audio/plugins/%40maru/hand-chord ; https://github.com/yusif-projects/dj-hands ; https://doi.org/10.13140/RG.2.2.17382.08007 ; https://github.com/ArmaanBudhiraja/AirString . Independently implement behavior; do not copy external code or assume licensing.

## Shared engine
Reuse existing camera tracking, source ownership, MIDI Helper, Instrument Builder and expressive routes. Two independently configurable roles, Chord/Note/Helper/Strum/Pluck/Drum/Disabled; swap handedness through explicit calibration, not screen X. Preserve one-hand legacy presets. Default disabled until explicit Start; camera frames local and transient. No new cloud or model dependency by default. Native camera path remains preferred.

Finger count 1–5 selects editable slots (example C,Dm,Em,F,G); zero defaults to mute for this preset. Selection does not emit notes. Optional explicit chord-on-pose mode is separate. Finger-pattern mode, bank selection, scale-degree mapping, inversions and microtonal tuning use existing validated note and tuning routes. Each finger can be assigned independently in a separate mode; do not conflate finger count and finger identity. Helper supports strum, pluck, expression, volume, pitch bend, wah, sustain, octave and arpeggio. Presets: Guitar, Baglama (custom tuning, tezene), Piano, Bass, Synth, Theremin, Orchestra and Hybrid. No claim of authentic makam from EDO alone.

## Safety and timing
Stable identity per session; ambiguous, swapped, occluded or invalid hand cannot trigger notes. Confidence threshold and palm-relative normalization; mirrored preview does not change physical hand role. Candidate chord debounce adjustable (initial design 120 ms); never delay existing note-off, watchdog, stop or disconnect deadlines. Reject nonfinite and stale samples before updating state. Use monotonic timestamps. On tracking loss release owned notes and pedals using existing safety path; no global panic that cuts unrelated local performers unless explicitly requested. On reacquisition require neutral/rearm; no replay. On chord change preserve snapshot for already sounding strum or explicitly release owned voices; never mix old/new chord within one stroke. No stuck notes on preset switch, camera switch, permission loss, stop, device disconnect or application quit. Existing global capture remains independent and unchanged.

Strum detects segment crossings in order, direction-aware, with per-string hysteresis and bounded events per frame; cannot infer unseen reversal between frames. Velocity derives from calibrated motion speed, not frame count. Pluck requires pinch edge and rearm. Continuous helper values coalesced/rate-limited using existing scheduler; prioritize release/edges and preserve established deadlines. Sustain source-specific ownership, MPE channel ownership and bounded polyphony. Reject unsupported tuning/output combinations rather than silently quantize. Do not bypass remote session reservations.

## UI
Dedicated Air workspace: camera selection, mirror preview, two hand confidence meters, role swap, per-hand role, editable numbered slots, pending vs committed chord, helper mapping, sensitivity, calibration, Start/Stop, source status, loss indicator and preset import/export. All controls use existing persistence/version validation. Low-cost preview and optional skeleton overlay; no decorative animation required. Camera-off state must release camera resource.

## Acceptance gates
1. All five counts select distinct configured slots without playing; zero mute; stable chord change after debounce.
2. Mirrored and unmirrored input, left-handed swap, crossed hands, reordered observations, ambiguous identity, partial occlusion.
3. Invalid numeric/confidence values, stale and out-of-order frames, duplicate samples; no notes.
4. Fast stroke crossing multiple strings, reverse direction, jitter, pinch rearm, chord change during stroke; balanced note-on/off.
5. Camera disconnect, permission revoke, stop, preset change and reacquire while pinched; bounded releases; no unintended note.
6. Independent trackpad/mouse/remote voices remain unaffected by camera cleanup, including sustain/MPE and global capture.
7. Backwards-compatible one-hand presets and saved settings; malformed import rejected atomically.
8. Replay deterministic synthetic landmark fixtures at 15/30/60 fps; record missed triggers and latency distributions, CPU and dropped frames with concurrent devices. Physical macOS camera and MIDI/haptic acceptance separate from CI.
9. No stable merge, release, install or physical PASS until acceptance. Design only; implementation and actual measurements pending.
