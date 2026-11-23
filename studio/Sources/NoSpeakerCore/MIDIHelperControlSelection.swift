/// Each MIDI Helper gesture can be enabled independently. Selecting all four
/// is equivalent to the old Hybrid mode, but Sustain may also run by itself.
public struct MIDIHelperControlSelection: Sendable, Equatable {
    public var vibrato: Bool
    public var pitchBend: Bool
    public var expression: Bool
    public var sustain: Bool

    public init(
        vibrato: Bool = true,
        pitchBend: Bool = false,
        expression: Bool = false,
        sustain: Bool = false
    ) {
        self.vibrato = vibrato
        self.pitchBend = pitchBend
        self.expression = expression
        self.sustain = sustain
    }

    public var isEmpty: Bool {
        !(vibrato || pitchBend || expression || sustain)
    }
}
