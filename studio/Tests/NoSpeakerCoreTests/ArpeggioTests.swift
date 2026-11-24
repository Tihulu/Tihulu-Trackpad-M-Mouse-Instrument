import Foundation
import Testing
@testable import NoSpeakerCore

@Test func arpeggioOrdersAndOctaveDeduplication() {
    let pad = ChordPad(name: "C", notes: [67,60,64])
    var arp = ArpeggioSettings()
    #expect(arp.noteOrder(for: pad) == [60,64,67])
    arp.order = .descending
    #expect(arp.noteOrder(for: pad) == [67,64,60])
    arp.order = .alternating
    #expect(arp.noteOrder(for: pad) == [60,64,67,64])
    arp.order = .ascending
    arp.octaves = 2
    #expect(arp.noteOrder(for: pad) == [60,64,67,72,76,79])
    let doubled = ChordPad(name: "Octaves", notes: [60,72])
    #expect(arp.noteOrder(for: doubled) == [60,72,84])
    let high = ChordPad(name: "High", notes: [120,127])
    #expect(arp.noteOrder(for: high) == [120,127])
}

@Test func arpeggioShuffleIsRepeatableAndContainsOnlyVoicing() {
    let pad = ChordPad(name: "Cmaj7", notes: [60,64,67,71])
    var arp = ArpeggioSettings()
    arp.order = .shuffle
    arp.octaves = 2
    let first = arp.noteOrder(for: pad)
    #expect(first == arp.noteOrder(for: pad))
    #expect(Set(first) == Set([60,64,67,71,72,76,79,83]))
    #expect(first.count == 8)
}

@Test func arpeggioTripletsPreserveRestsAndParentStepPositions() throws {
    var progression = ChordProgression()
    progression.slots = [0,nil,4]
    progression.beatsPerStep = 2
    progression.gatePercent = 50
    var arp = ArpeggioSettings()
    arp.notesPerBeat = 3
    progression.arpeggio = arp
    let plan = try #require(progression.plan(bank: ChordBank(), bpm: 120))
    #expect(plan.duration == 3)
    #expect(plan.steps.count == 13)
    #expect(plan.steps.prefix(6).allSatisfy { $0.position == 0 && $0.pad?.notes.count == 1 })
    #expect(plan.steps[6].position == 1 && plan.steps[6].pad == nil && plan.steps[6].onset == 1)
    #expect(plan.steps[7].position == 2 && plan.steps[7].onset == 2)
    #expect(abs(plan.steps[1].onset - 1.0/6) < 0.000001)
    #expect(abs(plan.steps[1].gate - 1.0/12) < 0.000001)
}

@Test func arpeggioArchiveCompatibilityAndBoundedPlan() throws {
    var progression = ChordProgression()
    let oldData = try JSONEncoder().encode(progression)
    #expect(try JSONDecoder().decode(ChordProgression.self, from: oldData).arpeggio == nil)
    var arp = ArpeggioSettings()
    arp.notesPerBeat = 8
    arp.octaves = 3
    progression.arpeggio = arp
    progression.slots = Array(repeating: 0, count: 16)
    let plan = try #require(progression.plan(bank: ChordBank(), bpm: 300))
    #expect(plan.steps.count == 512)
    let data = try WorkspaceArchive.encode(name: "Arp", payload: progression)
    #expect(try WorkspaceArchive.decode(ChordProgression.self, from: data).payload == progression)
    arp.notesPerBeat = 0
    progression.arpeggio = arp
    #expect(!progression.isValid)
    #expect(progression.plan(bank: ChordBank(), bpm: 120) == nil)
}
