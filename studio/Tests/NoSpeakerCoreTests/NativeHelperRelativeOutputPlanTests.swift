import Testing
@testable import NoSpeakerCore

private let bend = SensorDestination(.pitchBend, channel: 2)
private let mod = SensorDestination(.controlChange, channel: 2, number: 1)
private let gain = SensorDestination(.controlChange, channel: 2, number: 11)

private func plan() throws -> NativeHelperRelativeOutputPlan {
    try #require(NativeHelperRelativeOutputPlan(targets: [.x: bend, .y: mod, .contactSize: gain]))
}

@Test func nativeRelativeOutputAnchorDoesNotAcquireAndSparseMovementRetainsLanes() throws {
    let p = try plan()
    var owners = LegacyContinuousOwners()
    #expect(p.permitsAnchor(owners: owners, reservedChannels: []))
    #expect(p.prepare(movement: [:], owners: owners, reservedChannels: []) == [:])
    let first = try #require(p.prepare(movement: [.x: 9000, .contactSize: 80], owners: owners, reservedChannels: []))
    #expect(first[bend] == .init(9000, neutral: 8192))
    #expect(first[gain] == .init(80, neutral: 127, preserveOnRelease: true))
    _ = owners.replace(.helper, values: first)
    #expect(!p.permitsAnchor(owners: owners, reservedChannels: []))
    let second = try #require(p.prepare(movement: [.y: 25], owners: owners, reservedChannels: []))
    #expect(second[bend] == first[bend])
    #expect(second[gain] == first[gain])
    #expect(second[mod] == .init(25, neutral: 0))
    _ = owners.replace(.helper, values: second)
    let cleanup = owners.release(.helper)
    #expect(cleanup.contains(.init(bend, value: 8192)))
    #expect(cleanup.contains(.init(mod, value: 0)))
    #expect(cleanup.count == 2)
    #expect(p.permitsAnchor(owners: owners, reservedChannels: []))
}

@Test func nativeRelativeOutputRejectsHiddenAndNewConflictsAndReservedChannels() throws {
    let p = try plan()
    var owners = LegacyContinuousOwners()
    _ = owners.set(.touchBar, target: bend, value: .init(9000, neutral: 8192))
    #expect(!p.permitsAnchor(owners: owners, reservedChannels: []))
    #expect(p.prepare(movement: [.y: 25], owners: owners, reservedChannels: []) == nil)
    _ = owners.release(.touchBar)
    #expect(!p.permitsAnchor(owners: owners, reservedChannels: [2]))
    #expect(p.prepare(movement: [.x: 9000], owners: owners, reservedChannels: [2]) == nil)
    _ = owners.set(.helper, target: bend, value: .init(9000, neutral: 8192))
    _ = owners.set(.touchBar, target: bend, value: .init(9200, neutral: 8192))
    #expect(p.prepare(movement: [.x: 10000], owners: owners, reservedChannels: []) == nil)
    #expect(owners.values(for: .helper)[bend]?.value == 9000)
}

@Test func nativeRelativeOutputRejectsMalformedAndPreviousAbsoluteSnapshots() throws {
    let p = try plan()
    var owners = LegacyContinuousOwners()
    #expect(NativeHelperRelativeOutputPlan(targets: [:]) == nil)
    #expect(NativeHelperRelativeOutputPlan(targets: [.x: bend, .y: bend]) == nil)
    #expect(NativeHelperRelativeOutputPlan(targets: [.x: .init(.controlChange, number: 65)]) == nil)
    #expect(p.prepare(movement: [.x: 16384], owners: owners, reservedChannels: []) == nil)
    #expect(p.prepare(movement: [.y: -1], owners: owners, reservedChannels: []) == nil)
    _ = owners.set(.helper, target: bend, value: .init(9000, neutral: 8192, bendRange: 12))
    #expect(p.prepare(movement: [.x: 10000], owners: owners, reservedChannels: []) == nil)
    _ = owners.release(.helper)
    let foreign = SensorDestination(.controlChange, channel: 3, number: 74)
    _ = owners.set(.helper, target: foreign, value: .init(20, neutral: 0))
    #expect(p.prepare(movement: [.x: 10000], owners: owners, reservedChannels: []) == nil)
    #expect(owners.values(for: .helper)[foreign]?.value == 20)
}
