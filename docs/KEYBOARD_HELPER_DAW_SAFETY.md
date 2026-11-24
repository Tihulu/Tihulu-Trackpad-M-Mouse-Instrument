# External keyboard + MIDI Helper

Sustain-only is CC64 0/127, no Note On, velocity remapping, CC7, CC11, pitch bend, pressure or RPN. New defaults are sustain only. Existing saved explicit expressive settings remain; use Keyboard Sustain Only to switch. Pedal surfaces are excluded from effects unless deliberately shared. The Helper does not forward keyboard notes to the DAW. A sustained chord can naturally sound louder due to overlapping voices; that is not increased MIDI Note On velocity.

For explicitly enabled Helper CC7/11, releasing a gesture, disabling that mapping, Stop and Panic relinquish ownership without guessing an external baseline or sending 127. Another active internal owner may restore its own intentional value. A failed persistent gain submission requires manual DAW controller recovery, not a fabricated maximum-volume reset. Momentary bend/modulation and CC64 still receive their existing scoped cleanup. No claim of tracking another MIDI device's independent controller state.

Physical acceptance: monitor keyboard Note On velocity and CC7/11 before, during and after pedal press/release, toggling assignments, Stop and restart. Route physical keyboard directly to DAW, and NoSpeaker Touch MIDI Out to the same instrument/channel for Helper. Do not echo DAW output back into its input. External hardware pedal and Helper on same channel may conflict at receiver; use only one CC64 owner or DAW-side merge. Explicit pitch-range RPN changes the receiving instrument's channel range; match DAW configuration. Verify channel and track input filters; avoid sustain mapped to volume or velocity by MIDI Learn.

Helper pitch bend uses the receiver's existing bend range by default. RPN configuration is a separate advanced opt-in; disabling it does not restore an unknown receiver range. Dedicated physical MIDI monitor acceptance remains necessary.

Bulk continuous-owner release now respects persistent Helper gain just like scoped release. Live mapping changes invalidate the current Helper gesture and require an idle selected-surface frame before new onsets; clicks on excluded surfaces cannot trigger the pedal.

Opt-in output audit counts actual attempted legacy MIDI submissions by message category and channel, including failed submissions. No incoming note values, device identifiers or timestamps are retained. Test with other shared legacy producers stopped; the audit is not receiver confirmation. Finish it explicitly after Helper Stop to include cleanup messages. Fixed 100000-message counter limit.
