import Foundation
import Testing
@testable import NoSpeakerCore

private func mpeNote(_ note: Int, value: Int = 100) -> SensorCommand {
    .init(.init(.note, channel: 0, number: note), value: value)
}

@Test func chordMPEAllocatesIndependentBendsBeforeNoteOn() throws {
    var state = ChordMPEState()
    let firstResult = state.route(mpeNote(60), centsByPitchClass: [0:25,4:-30])
    let secondResult = state.route(mpeNote(64), centsByPitchClass: [0:25,4:-30])
    let first = try #require(firstResult)
    let second = try #require(secondResult)
    #expect(first.count == 2 && second.count == 2)
    #expect(first[0].destination.kind == .pitchBend && first[0].value == 9216)
    #expect(second[0].destination.kind == .pitchBend && second[0].value == 6963)
    #expect(first[1].destination.channel == 1 && second[1].destination.channel == 2)
    #expect(first[1].destination.number == 60 && second[1].destination.number == 64)
    let releaseResult = state.route(mpeNote(60, value: 0), centsByPitchClass: [:])
    let released = try #require(releaseResult)
    #expect(released.count == 1 && released[0].destination.channel == 1 && released[0].value == 0)
    #expect(state.activeCount == 1)
    let reused = state.route(mpeNote(67), centsByPitchClass: [:])
    #expect(reused?.first?.value == 8192 && reused?.last?.destination.channel == 1)
}

@Test func chordMPERefusesOverflowAndPreservesExistingOwners() {
    var state = ChordMPEState()
    for note in 60..<75 {
        let result = state.route(mpeNote(note), centsByPitchClass: [:])
        #expect(result?.count == 2)
    }
    let overflow = state.route(mpeNote(75), centsByPitchClass: [:])
    #expect(overflow == nil)
    #expect(state.activeCount == 15)
    let duplicate = state.route(mpeNote(60), centsByPitchClass: [:])
    #expect(duplicate?.isEmpty == true)
    state.clearAfterRelease()
    #expect(state.activeCount == 0)
}

@Test func chordMPEConfigurationHasValidRPNAndMemberBends() {
    let commands = ChordMPEState.configuration()
    #expect(commands.allSatisfy { $0.destination.isValid })
    let zone = commands.filter { $0.destination.kind == .controlChange && $0.destination.number == 6 }
    #expect(zone.first?.destination.channel == 15 && zone.first?.value == 0)
    #expect(zone.dropFirst().first?.destination.channel == 0 && zone.dropFirst().first?.value == 15)
    let bends = commands.filter { $0.destination.kind == .pitchBend }
    #expect(bends.count == 16 && bends.allSatisfy { $0.value == 8192 })
    #expect(ChordMPEState.bend(cents: 50) == nil)
}

@Test func chordMPEExplicitOptInAndArchive() throws {
    var bank = ChordBank()
    var scale = CustomScale()
    scale.centOffsets = [4:-30]
    bank.customScale = scale
    #expect(!bank.permitsSelectedOutput)
    bank.microtonalMPE = true
    #expect(bank.permitsSelectedOutput && bank.usesMPE)
    let data = try WorkspaceArchive.encode(name: "MPE", payload: bank)
    #expect(try WorkspaceArchive.decode(ChordBank.self, from: data).payload == bank)
    bank.output = .haptic
    #expect(!bank.usesMPE)
}
