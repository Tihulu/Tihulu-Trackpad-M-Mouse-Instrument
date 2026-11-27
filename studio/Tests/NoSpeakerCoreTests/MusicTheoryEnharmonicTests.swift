import Testing
@testable import NoSpeakerCore

@Test(arguments: Array(-2...10), Array(0..<7))
func singleAccidentalPitchSpellings(octave: Int, letterIndex: Int) throws {
    let letters = ["C", "D", "E", "F", "G", "A", "B"]
    let natural = [0, 2, 4, 5, 7, 9, 11]
    let letter = letters[letterIndex]
    for (suffix, offset) in [("", 0), ("#", 1), ("♯", 1), ("b", -1), ("♭", -1)] {
        let expected = (octave + 1) * 12 + natural[letterIndex] + offset
        for spelling in ["\(letter)\(suffix)\(octave)", " \(letter.lowercased())\(suffix)\(octave) "] {
            if (0...127).contains(expected) {
                #expect(try MusicTheory.midiNumber(note: spelling) == expected)
                #expect(try MusicTheory.frequency(note: spelling) == MusicTheory.frequency(midi: expected))
            } else {
                #expect(throws: MusicTheoryError.midiOutOfRange(expected)) {
                    try MusicTheory.midiNumber(note: spelling)
                }
            }
        }
    }
}

@Test func enharmonicSpellingDoesNotChangeCanonicalLabels() throws {
    for midi in 0...127 {
        let label = try MusicTheory.noteName(midi: midi)
        #expect(try MusicTheory.midiNumber(note: label) == midi)
    }
    #expect(try MusicTheory.midiNumber(note: "B#-2") == 0)
    #expect(try MusicTheory.midiNumber(note: "Cb0") == 11)
    #expect(try MusicTheory.midiNumber(note: "Fb4") == 64)
    #expect(try MusicTheory.midiNumber(note: "E#4") == 65)
    #expect(throws: MusicTheoryError.midiOutOfRange(-1)) { try MusicTheory.midiNumber(note: "Cb-1") }
}

@Test func enharmonicSpellingRejectsUnsupportedOrOverflowingNotation() {
    for note in ["C##4", "Dbb4", "E#b4", "B♯♯4", "Fb--1", "B#\(Int.max)", "Cb\(Int.min)"] {
        #expect(throws: MusicTheoryError.invalidNote(note)) { try MusicTheory.midiNumber(note: note) }
    }
}
