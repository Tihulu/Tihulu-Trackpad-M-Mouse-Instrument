/// Determines whether an existing touch voice must release its old note and
/// allocate a new member. Configuration and note changes under sustain must
/// not retune the previously released note through a reused MPE channel.
public enum LegacyTouchTransition {
    public static func requiresNewVoice(oldNote: Int, oldFretless: Bool, oldMPE: Bool,
                                        oldChannel: Int, newNote: Int, newFretless: Bool,
                                        newMPE: Bool, standardChannel: Int,
                                        sustained: Bool) -> Bool {
        oldMPE != newMPE || oldFretless != newFretless ||
            (!newMPE && oldChannel != standardChannel) ||
            (oldMPE && sustained && oldNote != newNote)
    }
}

/// Single-voice admission is sticky for the lifetime of the admitted
/// contact. Hardware array ordering is not a note release or onset.
public enum LegacyTouchAdmission {
    public static func preferredIndex<Key:Hashable>(keys:[Key],held:Set<Key>) -> Int? {
        keys.firstIndex { held.contains($0) } ?? keys.indices.first
    }
}
