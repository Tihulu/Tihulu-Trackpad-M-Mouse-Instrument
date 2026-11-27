import Testing
@testable import NoSpeakerCore

@Test func relativeCCPickerPreservesAbsoluteChoices() {
    let absolute = HelperCCPolicy.choices
    let relative = NativeHelperRelativeCCChoices.choices(channel: 0)
    #expect(absolute.count == 109)
    #expect(relative.count == 104)
    #expect(absolute.filter { !relative.contains($0) } == Array(65...69))
    #expect(NativeHelperRelativeCCChoices.choices(channel: -1).isEmpty)
    #expect(NativeHelperRelativeCCChoices.choices(channel: 16).isEmpty)
    #expect(NativeHelperRelativeCCChoices.choices(channel: 0, otherEnabledCC: 7) == relative.filter { $0 != 7 })
    #expect(NativeHelperRelativeCCChoices.choices(channel: 0, otherEnabledCC: 64) == relative)
}

@Test(arguments: Array(0..<16)) func relativeCCPickerMatchesPlan(channel: Int) {
    let choices = NativeHelperRelativeCCChoices.choices(channel: channel)
    for cc in -1...128 {
        let target = SensorDestination(.controlChange, channel: channel, number: cc)
        #expect(choices.contains(cc) == (NativeHelperRelativeOutputPlan(targets: [.y: target]) != nil))
    }
}

@Test(arguments: [1, 7, 11, 74]) func relativeCCReleasePreservesPersistentGain(cc: Int) throws {
    let target = SensorDestination(.controlChange, channel: 0, number: cc)
    let plan = try #require(NativeHelperRelativeOutputPlan(targets: [.y: target]))
    let persistent = [7, 11].contains(cc)
    var owners = LegacyContinuousOwners()
    var transaction = NativeHelperRelativeOutputTransaction(plan: plan)
    var sent: [LegacyContinuousOwners.Update] = []
    let anchored = transaction.anchor(owners: &owners, reservedChannels: [], permits: { true })
    #expect(anchored == .anchored)
    let moved = transaction.movement([.y: 33], owners: &owners, reservedChannels: [], permits: { true }, send: { sent.append($0); return true })
    #expect(moved == .accepted)
    #expect(sent.count == 1)
    #expect(sent.first?.preserveOnRelease == persistent)
    _ = transaction.retire()
    let released = owners.release(.helper)
    #expect(released == (persistent ? [] : [.init(target, value: 0)]))
    let dirty = transaction.confirmCleanup(owners: &owners, genuineNeutral: true, transportClean: false)
    #expect(!dirty)
    let clean = transaction.confirmCleanup(owners: &owners, genuineNeutral: true, transportClean: true)
    #expect(clean)
}
