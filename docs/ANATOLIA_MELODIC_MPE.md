# Anatolia — melodic Touch MPE checkpoint

Custom root-relative cent offsets now have a melodic Touch MPE path through the existing isolated member-channel allocator, controller ledger and sustain reservation. Pitch is set on the member before Note On with +/-2 semitone range. Moving between degrees retires the previous voice; no note stealing or fallback when member channels are unavailable. Standard MIDI still requires explicit 12-TET approximation. Continuous fretless and string layouts keep their own pitch models; drum and physical chord behavior is unchanged.

This is custom intonation, not a complete makam/seyir implementation. Confirm actual receiver MPE configuration, pitch bend range, two different simultaneous cent offsets, note changes under sustain, member exhaustion, and Stop/Panic using a physical MIDI monitor. Automated tests cover pitch conversion and configuration gating; real MIDI delivery acceptance remains pending.
