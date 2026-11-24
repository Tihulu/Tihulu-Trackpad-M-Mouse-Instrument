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
