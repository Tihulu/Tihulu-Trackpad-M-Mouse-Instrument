import Foundation
import Testing
@testable import NoSpeakerCore

@Test func noteOutputChoicesAndOldChordBanks() throws {
    #expect(MusicalOutput.midi.sendsMIDI && !MusicalOutput.midi.sendsHaptics)
    #expect(!MusicalOutput.haptic.sendsMIDI && MusicalOutput.haptic.sendsHaptics)
    #expect(MusicalOutput.both.sendsMIDI && MusicalOutput.both.sendsHaptics)
    let old = ChordBank()
    let data = try JSONEncoder().encode(old)
    #expect(try JSONDecoder().decode(ChordBank.self, from: data).effectiveOutput == .midi)
    var bank = old
    bank.output = .both
    #expect(try JSONDecoder().decode(ChordBank.self, from: JSONEncoder().encode(bank)).effectiveOutput == .both)
}

@Test func noteHapticsPreserveChordFrequenciesAndBoundLevel() throws {
    let frame = try #require(NoteHapticRenderer.frame(notes: [60,64,67], velocity: 96))
    #expect(frame.tones.count == 3)
    for (index, note) in [60,64,67].enumerated() {
        let hz = try MusicTheory.frequency(midi: note)
        #expect(abs(frame.tones[index].frequencyHz - hz) < 0.00001)
    }
    #expect(frame.level <= 1)
    #expect(frame.durationMS == 18)
    #expect(abs(frame.tones.reduce(0) { $0 + $1.amplitude } - 1) < 0.00001)
}

@Test func noteHapticsFoldOctavesAndLimitPolyphony() throws {
    let frame = try #require(NoteHapticRenderer.frame(notes: [0,48,60,61,62,63,64,65,66,67,127], velocity: 127))
    #expect(frame.tones.count <= 6)
    #expect(frame.tones.allSatisfy { (98...3951).contains($0.frequencyHz) })
    #expect(frame == HapticSafetyPolicy().clamp(frame))
    let folded = try #require(NoteHapticRenderer.frame(notes: [0,24,36,48], velocity: 100))
    #expect(folded.tones.count == 1)
    #expect(NoteHapticRenderer.frame(notes: [], velocity: 100) == nil)
    #expect(NoteHapticRenderer.frame(notes: [-1,128], velocity: 100) == nil)
    #expect(NoteHapticRenderer.frame(notes: [60], velocity: 0) == nil)
}

@Test func noteHapticStateFollowsOverlappingChordOwnership() {
    var state = ChordPadState()
    _ = state.press(slot: 0, pad: .init(name: "C", notes: [60,64,67]), channel: 0, velocity: 100)
    _ = state.press(slot: 1, pad: .init(name: "Am", notes: [57,60,64]), channel: 0, velocity: 100)
    #expect(state.activeNotes == [57,60,64,67])
    _ = state.release(slot: 0)
    #expect(state.activeNotes == [57,60,64])
    _ = state.releaseAll()
    #expect(NoteHapticRenderer.frame(notes: state.activeNotes, velocity: 100) == nil)
}


@Test func touchHapticVoicingFoldsBassRatherThanFlatteningPitch() throws {
    let a = try #require(TouchHapticVoicing.foldedFrequency(55))
    let b = try #require(TouchHapticVoicing.foldedFrequency(65))
    #expect(a == 110 && b == 130)
    #expect(TouchHapticVoicing.foldedFrequency(4000) == 2000)
    #expect(TouchHapticVoicing.foldedFrequency(.nan) == nil)
    #expect(TouchHapticVoicing.foldedFrequency(0) == nil)
    #expect(TouchHapticVoicing.foldedFrequency(Double.greatestFiniteMagnitude) == nil)
}

@Test func touchHapticVoicingPreservesRelativeFingerVelocity() throws {
    let frame = try #require(TouchHapticVoicing.frame([
        .init(frequencies:[220],gain:0.2),.init(frequencies:[440],gain:0.6)
    ]))
    #expect(abs(frame.level-0.8) < 0.000001)
    #expect(abs(frame.tones[0].amplitude-0.25) < 0.000001)
    #expect(abs(frame.tones[1].amplitude-0.75) < 0.000001)
    let soft = try #require(TouchHapticVoicing.frame([.init(frequencies:[220],gain:0.02)]))
    #expect(soft.level == 0.02)
}

@Test func touchHapticVoicingSharesBudgetAcrossChordAndMelodicContacts() throws {
    let frame = try #require(TouchHapticVoicing.frame([
        .init(frequencies:[110,220,330,440,550,660],gain:1),
        .init(frequencies:[261.6],gain:0.5),.init(frequencies:[392],gain:0.5)
    ]))
    #expect(frame.tones.count == 6)
    #expect(frame.tones.map(\.frequencyHz).prefix(3) == [110,261.6,392])
    #expect(frame.level <= 1)
}

@Test func touchHapticVoicingDeduplicatesFoldedNotesWithoutGainBoost() throws {
    let frame = try #require(TouchHapticVoicing.frame([
        .init(frequencies:[55,110],gain:0.3),.init(frequencies:[110],gain:0.4)
    ]))
    #expect(frame.tones.count == 1)
    #expect(frame.tones.first?.frequencyHz == 110)
    #expect(frame.level == 0.4)
    #expect(TouchHapticVoicing.frame([.init(frequencies:[440],gain:.nan)]) == nil)
    #expect(TouchHapticVoicing.frame([.init(frequencies:[440],gain:0)]) == nil)
}
