import Testing
@testable import NoSpeakerCore

@Test func helperControlsAreIndependentAndCanBeSustainOnly() {
    let sustainOnly = MIDIHelperControlSelection(
        vibrato: false,
        pitchBend: false,
        expression: false,
        sustain: true
    )
    #expect(sustainOnly.sustain)
    #expect(!sustainOnly.vibrato)
    #expect(!sustainOnly.pitchBend)
    #expect(!sustainOnly.expression)
    #expect(!sustainOnly.isEmpty)

    let none = MIDIHelperControlSelection(
        vibrato: false, pitchBend: false,
        expression: false, sustain: false
    )
    #expect(none.isEmpty)
}

@Test func helperControlsCanCombineAnySubset() {
    let hybrid = MIDIHelperControlSelection(
        vibrato: true, pitchBend: true,
        expression: true, sustain: true
    )
    #expect(!hybrid.isEmpty)

    let bendAndSustain = MIDIHelperControlSelection(
        vibrato: false, pitchBend: true,
        expression: false, sustain: true
    )
    #expect(bendAndSustain.pitchBend)
    #expect(bendAndSustain.sustain)
    #expect(!bendAndSustain.vibrato)
    #expect(!bendAndSustain.expression)
}
