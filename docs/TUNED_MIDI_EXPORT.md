# Tuned MIDI export

Chord Progression and Note Sequencer expose a separate tuned MPE export when the current custom bank scale contains nonzero cent offsets. The existing nominal export is explicitly labeled 12-TET. Export is file-only and never changes a live MIDI endpoint.

Single-instrument SMF format 0, 960 PPQ, fixed tempo, lower-zone RPN and ±2 semitone pitch bend setup before note events. Every overlapping note has a separate member; each member retains one bend for the whole file to avoid changing release-tail tuning. Up to 15 members; clips needing more fixed-bend members fail rather than approximate. Channels are remapped, not preserved as multiple independent instruments. Trailing rests and velocity preserved. No sustain automation, live sequencer retuning, dense 24/53-EDO string export or full makam/seyir engine in this checkpoint.

Import into a dedicated MPE instrument with channel, RPN and pitch events preserved; DAW import behavior varies. Verify actual pitch, simultaneous notes, release tails and Note Off ordering with a physical MIDI monitor and tuner. The file parser test checks note timing/velocity; byte tests check tuning messages.
