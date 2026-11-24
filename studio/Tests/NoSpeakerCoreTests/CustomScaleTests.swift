import Foundation
import Testing
@testable import NoSpeakerCore

@Test func customScaleGeneratesChordsAndRootRelativeTuning() throws {
    var bank = ChordBank()
    bank.root = 62
    var scale = CustomScale()
    scale.intervals = [0,2,3,7,9]
    scale.centOffsets = [3:-25,9:20]
    bank.customScale = scale
    #expect(bank.isValid)
    #expect(bank.pad(at: 0)?.notes == [62,65,71])
    #expect(bank.centsByPitchClass == [5:-25,11:20])
    let frame = try #require(NoteHapticRenderer.frame(notes: [65,71], velocity: 100,
                                                       centsByPitchClass: bank.centsByPitchClass))
    let f = try MusicTheory.frequency(midi: 65) * pow(2, -25.0/1200)
    let g = try MusicTheory.frequency(midi: 71) * pow(2, 20.0/1200)
    #expect(abs(frame.tones[0].frequencyHz - f) < 0.000001)
    #expect(abs(frame.tones[1].frequencyHz - g) < 0.000001)
}

@Test func customScaleValidationAndMIDIGate() {
    var bank = ChordBank()
    var scale = CustomScale()
    scale.centOffsets = [4:-30]
    bank.customScale = scale
    #expect(!bank.permitsSelectedOutput)
    bank.output = .haptic
    #expect(bank.permitsSelectedOutput)
    bank.output = .both
    #expect(!bank.permitsSelectedOutput)
    scale.allowEqualTemperedMIDI = true
    bank.customScale = scale
    #expect(bank.permitsSelectedOutput)
    scale.centOffsets = [4:50]
    #expect(!scale.isValid)
    scale.centOffsets = [1:10]
    #expect(!scale.isValid)
    scale.centOffsets = [:]
    scale.intervals = [0,4,4]
    #expect(!scale.isValid)
}

@Test func customScaleArchiveAndArpeggioReuse() throws {
    let old = ChordBank()
    let oldData = try JSONEncoder().encode(old)
    let decoded = try JSONDecoder().decode(ChordBank.self, from: oldData)
    #expect(decoded.customScale == nil)
    var bank = old
    var scale = CustomScale()
    scale.intervals = [0,2,5,7,10]
    scale.centOffsets = [5:20]
    bank.customScale = scale
    let archive = try WorkspaceArchive.encode(name: "Custom scale", payload: bank)
    let restored = try WorkspaceArchive.decode(ChordBank.self, from: archive).payload
    #expect(restored == bank)
    var progression = ChordProgression()
    progression.slots = [0]
    progression.arpeggio = ArpeggioSettings()
    let plan = try #require(progression.plan(bank: bank, bpm: 120))
    #expect(plan.steps.prefix(3).compactMap { $0.pad?.notes.first } == [60,65,70])
    let tuned = try #require(NoteHapticRenderer.frame(notes: [65], velocity: 96,
                                                      centsByPitchClass: bank.centsByPitchClass))
    let base = try MusicTheory.frequency(midi: 65)
    #expect(abs(tuned.tones[0].frequencyHz - base * pow(2, 20.0/1200)) < 0.000001)
}

@Test func customTuningPreservesFoldedPitchClassAndSafety() throws {
    let offsets = [0:25]
    let frame = try #require(NoteHapticRenderer.frame(notes: [0,12,24,36,48,60,72,84], velocity: 100,
                                                       centsByPitchClass: offsets))
    #expect(frame.tones.count <= 6)
    #expect(frame == HapticSafetyPolicy().clamp(frame))
    let nominal = try MusicTheory.frequency(midi: 48)
    #expect(abs(frame.tones[0].frequencyHz - nominal * pow(2, 25.0/1200)) < 0.000001)
    #expect(NoteHapticRenderer.frame(notes: [60], velocity: 100, centsByPitchClass: [0:100]) == nil)
}
