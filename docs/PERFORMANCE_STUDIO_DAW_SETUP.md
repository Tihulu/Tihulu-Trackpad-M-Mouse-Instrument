# Performance Studio — DAW Setup Assistant

## Delivered first slice (Builder only)
Base: #160 exact 40974f87a4a1101f3e3b9d18d10524c04b5a7b6d, completed CI 45585652552 success.
Replaces the old logical-only routing disclosure with a read-only assistant. Derives configured MIDI rows from the patch and the same split-output policy as Builder; excludes haptic-only slots; invalid/empty/off choices expose no port. Uses frozen active output flags while running. Tuned Air uses a dedicated port, hides logical channels and requires host validation. This is configuration guidance, not proof of endpoint registration, receiver acceptance or audio. No sends, timers, drivers, external app launches on opening, automation or changes to playback. Explicit Copy and official-guide links only. EN/TR/DE guidance text; full interface localization remains open.

Logic, GarageBand, Ableton Live, REAPER, generic DAW profiles. GarageBand: advise a single intended sound or sequential recording; do not claim independent filtering or MPE support. Manual test one note, sustain and effect; feedback/loopback acceptance is not automatic. Existing code paths unchanged except read-only UI projection.

## Remaining central routing phases
1. Persistent UUID group identity separate from editable display name/color/icon and stable endpoint ID/name; validation and migration of saved profiles. Copy/delete/reorder must never silently reuse endpoint identity.
2. Central group assignment graph: multiple note and Helper sources per group, per-signal assignments, explicit multi-group layering. Use one ownership ledger per port/channel/note or CC; no duplicated engine. Same control collisions need explicit arbitration; sustain first-on/last-off; continuous neutral only when last owner releases.
3. Standard independent group ports; MPE per-group port and global/member zone, explicit bend-range compatibility, no silent 12-TET fallback. Keep current fixed-channel and dedicated endpoints compatible. Group stop/mute/panic scoped; global Panic terminal; failed cleanup debt blocks unsafe rearm.
4. Expand assistant from Builder channels to actual validated group snapshots; display user group names, stable port, channels, note/Helper/CC assignments, per-group setup sheet; verify missing ports and receiver routing separately. Add per-DAW version selection, MainStage/Cubase/FL Studio/Bitwig after verified guides. Localized full UI and group settings persistence.
5. Explicit scoped diagnostic test route only when safe: bounded note on/off and cleanup, optional CC reset of owned control, no test while conflicting active owners, failed release retained. Distinguish local ready / send accepted / DAW input confirmed / audio confirmed; never claim success from send alone.
6. Regression matrix: rename/reorder, source disconnect/rearm, same notes, overlapping sustain, shared CC and MPE conflicts, group/profile switch, stale events, overload, no-send guide, GarageBand limitation, physical Mac/DAW acceptance. Preserve existing timing and haptic limits; no stable merge/release/install without gates.

## References
- Apple Logic Pro: https://support.apple.com/guide/logicpro/lgcp8a4693ee/mac
- Apple GarageBand: https://support.apple.com/guide/garageband/welcome/mac
- Ableton: https://www.ableton.com/en/manual/routing-and-i-o/
- REAPER: https://www.reaper.fm/userguide.php

Five core regression tests authored; full CI and physical acceptance pending at creation. No claim of complete Performance Studio or independent group ports. User approved the assistant; implementation deliberately starts with existing Builder and no automated MIDI testing.
