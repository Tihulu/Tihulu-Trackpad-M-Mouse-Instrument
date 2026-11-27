import Testing
@testable import NoSpeakerCore

private let hostBend = SensorDestination(.pitchBend, channel: 2)
private let hostCC = SensorDestination(.controlChange, channel: 2, number: 74)
private let hostTargets: Set<SensorDestination> = [hostBend, hostCC]

@Test func relativeHostKeepsRetiredChannelsReservedUntilCleanup() throws {
    var owners = LegacyContinuousOwners()
    let result = owners.reserveRelativeHelper(targets: hostTargets)
    let token = try #require(result)
    #expect(NativeHelperRelativeHostPolicy.reservedChannels(targets: owners.relativeReservedTargets) == [2])
    owners.invalidateRelativeHelper(token)
    #expect(NativeHelperRelativeHostPolicy.reservedChannels(targets: owners.relativeReservedTargets) == [2])
    let dirty = owners.finishRelativeHelper(token, transportClean: false)
    #expect(!dirty)
    let clean = owners.finishRelativeHelper(token, transportClean: true)
    #expect(clean && owners.relativeReservedTargets.isEmpty)
}

@Test func relativeHostDirectCCFenceProtectsSameTargetAndChannelModeButNotSustain() {
    for cc in 0...127 {
        let expected = [0,6,32,38,74,96,97,98,99,100,101].contains(cc) || (120...127).contains(cc)
        #expect(NativeHelperRelativeHostPolicy.conflictsWithDirectCC(channel: 2, controller: cc, targets: hostTargets) == expected)
        #expect(!NativeHelperRelativeHostPolicy.conflictsWithDirectCC(channel: 3, controller: cc, targets: hostTargets))
        #expect(!NativeHelperRelativeHostPolicy.conflictsWithDirectCC(channel: 2, controller: cc, targets: []))
    }
}

@Test func relativeHostCleanupTracksExactTargetAndFailedNeutral() {
    var debt = LegacyControllerReleaseDebt()
    debt.record(.init(0xb3, 74, 90), neutral: 0, succeeded: true)
    debt.record(.init(0xb2, 71, 70), neutral: 0, succeeded: true)
    #expect(!NativeHelperRelativeHostPolicy.hasPendingCleanup(targets: hostTargets, debt: debt))
    debt.record(.init(0xb2, 74, 90), neutral: 0, succeeded: false)
    #expect(NativeHelperRelativeHostPolicy.hasPendingCleanup(targets: hostTargets, debt: debt))
    debt.record(.init(0xb2, 74, 0), neutral: 0, succeeded: false)
    #expect(NativeHelperRelativeHostPolicy.hasPendingCleanup(targets: hostTargets, debt: debt))
    debt.record(.init(0xb2, 74, 0), neutral: 0, succeeded: true)
    #expect(!NativeHelperRelativeHostPolicy.hasPendingCleanup(targets: hostTargets, debt: debt))
    debt.record(.init(0xe2, 1, 70), neutral: 8192, succeeded: true)
    #expect(NativeHelperRelativeHostPolicy.hasPendingCleanup(targets: hostTargets, debt: debt))
    debt.record(.init(0xe2, 0, 64), neutral: 8192, succeeded: true)
    #expect(!NativeHelperRelativeHostPolicy.hasPendingCleanup(targets: hostTargets, debt: debt))
    debt.beginRange(channel: 3)
    #expect(!NativeHelperRelativeHostPolicy.hasPendingCleanup(targets: hostTargets, debt: debt))
    debt.beginRange(channel: 2)
    #expect(NativeHelperRelativeHostPolicy.hasPendingCleanup(targets: hostTargets, debt: debt))
    debt.completeRange(channel: 2)
    #expect(!NativeHelperRelativeHostPolicy.hasPendingCleanup(targets: hostTargets, debt: debt))
    #expect(!debt.isEmpty)
}
