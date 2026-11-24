import Foundation
import Testing
@testable import NoSpeakerCore

@Test func majorScaleChordsAndInversion() throws {
    var bank = ChordBank()
    #expect(bank.pad(at: 0)?.notes == [60,64,67])
    #expect(bank.pad(at: 1)?.notes == [62,65,69])
    #expect(bank.pad(at: 6)?.notes == [71,74,77])
    #expect(bank.pad(at: 7)?.notes == [72,76,79])
    bank.stack = .sevenths
    #expect(bank.pad(at: 4)?.name == "G7")
    bank.inversion = 1
    #expect(bank.pad(at: 0)?.notes == [64,67,71,72])
}

@Test func allScaleStacksProduceBoundedUniqueNotes() throws {
    for scale in ChordScale.allCases {
        for stack in ChordStack.allCases {
            for root in [36,71] {
                for inversion in 0...2 {
                    var bank = ChordBank()
                    bank.scale = scale
                    bank.stack = stack
                    bank.root = root
                    bank.inversion = inversion
                    for i in 0..<ChordBank.padCount {
                        let pad = try #require(bank.pad(at: i))
                        #expect(pad.isValid)
                    }
                }
            }
        }
    }
}

@Test func customPadSurvivesScaleAndArchiveRoundTrip() throws {
    var bank = ChordBank()
    let custom = ChordPad(name: "My voicing", notes: [48,55,62,67])
    bank.overrides[2] = custom
    bank.scale = .hicaz
    bank.root = 45
    #expect(bank.pad(at: 2) == custom)
    let data = try WorkspaceArchive.encode(name: "Chord bank", payload: bank)
    let decoded = try WorkspaceArchive.decode(ChordBank.self, from: data)
    #expect(decoded.payload == bank)
    bank.overrides.removeValue(forKey: 2)
    #expect(bank.pad(at: 2) != custom)
}

@Test func invalidCustomChordsAndBankAreRejected() {
    var bank = ChordBank()
    bank.overrides[0] = .init(name: "Bad", notes: [60,60])
    #expect(!bank.isValid)
    #expect(bank.pad(at: 0) == nil)
    bank.overrides = [8: .init(name: "Outside", notes: [60])]
    #expect(!bank.isValid)
    bank.overrides = [:]
    bank.root = 128
    #expect(!bank.isValid)
}

@Test func overlappingChordsReleaseSharedNotesOnlyAfterLastPad() {
    var state = ChordPadState()
    let a = ChordPad(name: "C", notes: [60,64,67])
    let b = ChordPad(name: "Am", notes: [57,60,64])
    #expect(state.press(slot: 0, pad: a, channel: 0, velocity: 90).count == 3)
    #expect(state.press(slot: 0, pad: a, channel: 0, velocity: 90).isEmpty)
    #expect(state.press(slot: 1, pad: b, channel: 0, velocity: 90).map { $0.destination.number } == [57])
    #expect(state.release(slot: 0).map { $0.destination.number } == [67])
    #expect(state.release(slot: 1).map { $0.destination.number } == [57,60,64])
    #expect(state.releaseAll().isEmpty)
}

@Test func chordReleaseRetainsOriginalChannelAndVoicing() {
    var state = ChordPadState()
    let pad = ChordPad(name: "C", notes: [60,64,67])
    _ = state.press(slot: 0, pad: pad, channel: 4, velocity: 100)
    let off = state.releaseAll()
    #expect(off.count == 3)
    #expect(off.allSatisfy { $0.destination.channel == 4 && $0.value == 0 })
    #expect(state.activeSlots.isEmpty)
}

@Test func chordNoteEntrySupportsNamesFlatsAndMIDINumbers() {
    #expect(ChordPad.parseNotes("C4 E4 G4 Bb4") == [60,64,67,70])
    #expect(ChordPad.parseNotes("C-1, 64, F#4, G9") == [0,64,66,127])
    #expect(ChordPad.parseNotes("C4 60") == nil)
    #expect(ChordPad.parseNotes("C4 invalid") == nil)
    #expect(ChordPad.parseNotes("G#9") == nil)
    #expect(ChordPad.parseNotes("C9999999") == nil)
}
