/// Scoped recovery of the sequencer's actual attempted MIDI output.
/// The caller retains the original endpoint until both ledgers are clean.
public enum SequencerMIDIRecovery {
    public static func release(notes: inout MIDIClipNoteLedger,
                               selectors: inout MIDISelectorCleanup,
                               send: (SensorCommand) -> Bool) -> Bool {
        let notesReleased = notes.releaseAll(send: send)
        // Never short-circuit: incomplete notes must not prevent RPN nulling.
        let selectorsReleased = selectors.releaseAll(send: send)
        return notesReleased && selectorsReleased
    }
}
