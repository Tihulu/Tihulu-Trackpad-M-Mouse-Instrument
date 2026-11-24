import Foundation
import Testing
@testable import NoSpeakerCore

@Test func progressionResolvesBankAndRestWithFullDuration() throws {
    var pattern = ChordProgression()
    pattern.slots = [0, nil, 4, 5]
    pattern.beatsPerStep = 2
    pattern.gatePercent = 50
    var bank = ChordBank()
    bank.channel = 3
    bank.velocity = 101
    bank.overrides[4] = .init(name: "Custom", notes: [60,64,67,71,74])
    let plan = try #require(pattern.plan(bank: bank, bpm: 120))
    #expect(plan.duration == 4)
    #expect(plan.steps.map(\.onset) == [0,1,2,3])
    #expect(plan.steps.map(\.gate) == [0.5,0.5,0.5,0.5])
    #expect(plan.steps[1].pad == nil)
    #expect(plan.steps[2].pad == bank.overrides[4])
    #expect(plan.channel == 2 && plan.velocity == 101)
}

@Test func progressionRejectsMalformedAndSilentPlans() {
    var pattern = ChordProgression()
    let bank = ChordBank()
    pattern.slots = [nil,nil]
    #expect(pattern.plan(bank: bank, bpm: 120) == nil)
    pattern.slots = [8]
    #expect(!pattern.isValid)
    pattern.slots = [0]
    pattern.gatePercent = 101
    #expect(!pattern.isValid)
    pattern.gatePercent = 100
    pattern.beatsPerStep = 3
    #expect(!pattern.isValid)
    pattern.beatsPerStep = 4
    #expect(pattern.plan(bank: bank, bpm: .nan) == nil)
    #expect(pattern.plan(bank: bank, bpm: 0) == nil)
    pattern.slots = Array(repeating: 0, count: 17)
    #expect(!pattern.isValid)
}

@Test func progressionArchiveAndScaleChanges() throws {
    var pattern = ChordProgression()
    pattern.loop = false
    let data = try WorkspaceArchive.encode(name: "Progression", payload: pattern)
    let recovered = try WorkspaceArchive.decode(ChordProgression.self, from: data).payload
    #expect(recovered == pattern)
    var bank = ChordBank()
    let major = try #require(pattern.plan(bank: bank, bpm: 120))
    bank.scale = .naturalMinor
    let minor = try #require(pattern.plan(bank: bank, bpm: 120))
    #expect(major.steps[0].pad != minor.steps[0].pad)
    #expect(!minor.loop)
    #expect(major.duration == minor.duration)
}

@Test func progressionUsesFullMIDIChordAndBoundedHapticVoicing() throws {
    var bank = ChordBank()
    bank.overrides[0] = .init(name: "Extended", notes: [36,48,60,64,67,71,74,77])
    let plan = try #require(ChordProgression().plan(bank: bank, bpm: 120))
    let pad = try #require(plan.steps[0].pad)
    var state = ChordPadState()
    let commands = state.press(slot: 0, pad: pad, channel: plan.channel, velocity: plan.velocity)
    #expect(commands.count == 8)
    let frame = try #require(NoteHapticRenderer.frame(notes: state.activeNotes, velocity: plan.velocity))
    #expect(frame.tones.count <= 6)
    let release = state.release(slot: 0)
    #expect(release.count == 8 && state.activeNotes.isEmpty)
}
