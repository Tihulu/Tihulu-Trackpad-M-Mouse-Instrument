import Foundation
import Testing
@testable import NoSpeakerCore

private let transactionCC = SensorDestination(.controlChange, channel: 2, number: 1)
private let transactionBend = SensorDestination(.pitchBend, channel: 2)
private func transaction() throws -> NativeHelperRelativeOutputTransaction {
    let plan = try #require(NativeHelperRelativeOutputPlan(targets: [.x: transactionBend, .y: transactionCC]))
    return .init(plan: plan)
}

@Test func relativeTransactionCommitsOnlyAdmittedPrefixAndRequiresCleanup() throws {
    var state = try transaction(), owners = LegacyContinuousOwners()
    var attempts: [LegacyContinuousOwners.Update] = []
    #expect(state.anchor(owners: &owners, reservedChannels: [], permits: { true }) == .anchored)
    #expect(owners.values(for: .helper).isEmpty)
    let result = state.movement([.x: 9000, .y: 50], owners: &owners, reservedChannels: [], permits: { true }) {
        attempts.append($0)
        return $0.target == transactionCC
    }
    #expect(result == .releaseRequired)
    #expect(attempts.map(\.target) == [transactionCC, transactionBend])
    #expect(owners.values(for: .helper) == [transactionCC: .init(50, neutral: 0)])
    let blocked = state.movement([.x: 9500], owners: &owners, reservedChannels: [], permits: { true }) {
        attempts.append($0); return true
    }
    #expect(blocked == .blocked && attempts.count == 2)
    let premature = state.confirmCleanup(owners: &owners, genuineNeutral: true, transportClean: true)
    #expect(!premature)
    #expect(owners.release(.helper) == [.init(transactionCC, value: 0)])
    let debt = state.confirmCleanup(owners: &owners, genuineNeutral: true, transportClean: false)
    let held = state.confirmCleanup(owners: &owners, genuineNeutral: false, transportClean: true)
    #expect(!debt && !held)
    #expect(state.anchor(owners: &owners, reservedChannels: [], permits: { true }) == .blocked)
    let clean = state.confirmCleanup(owners: &owners, genuineNeutral: true, transportClean: true)
    #expect(clean)
    #expect(state.anchor(owners: &owners, reservedChannels: [], permits: { true }) == .anchored)
}

@Test func relativeTransactionChecksAdmissionBeforeEachTargetAndAfterLastSend() throws {
    var state = try transaction(), owners = LegacyContinuousOwners()
    var attempts: [LegacyContinuousOwners.Update] = []
    _ = state.anchor(owners: &owners, reservedChannels: [], permits: { true })
    let late = state.movement([.x: 9000, .y: 50], owners: &owners, reservedChannels: [], permits: { attempts.isEmpty }) {
        attempts.append($0); return true
    }
    #expect(late == .releaseRequired)
    #expect(attempts.map(\.target) == [transactionCC])
    #expect(owners.values(for: .helper)[transactionCC]?.value == 50)
    #expect(owners.values(for: .helper)[transactionBend] == nil)
    _ = owners.release(.helper)
    _ = state.confirmCleanup(owners: &owners, genuineNeutral: true, transportClean: true)
    _ = state.anchor(owners: &owners, reservedChannels: [], permits: { true })
    attempts.removeAll()
    let afterLast = state.movement([.x: 9000], owners: &owners, reservedChannels: [], permits: { attempts.isEmpty }) {
        attempts.append($0); return true
    }
    #expect(afterLast == .releaseRequired)
    #expect(owners.values(for: .helper)[transactionBend]?.value == 9000)
}

@Test func relativeTransactionRejectsExternalOwnershipChangeAndCompetingLane() throws {
    var state = try transaction(), owners = LegacyContinuousOwners()
    _ = state.anchor(owners: &owners, reservedChannels: [], permits: { true })
    _ = owners.set(.helper, target: transactionCC, value: .init(40, neutral: 0))
    var attempted = false
    let changed = state.movement([.y: 50], owners: &owners, reservedChannels: [], permits: { true }) { _ in
        attempted = true; return true
    }
    #expect(changed == .releaseRequired && !attempted)
    _ = owners.release(.helper)
    _ = state.confirmCleanup(owners: &owners, genuineNeutral: true, transportClean: true)
    _ = state.anchor(owners: &owners, reservedChannels: [], permits: { true })
    _ = owners.set(.touchBar, target: transactionBend, value: .init(8200, neutral: 8192))
    let conflict = state.movement([.y: 50], owners: &owners, reservedChannels: [], permits: { true }) { _ in
        attempted = true; return true
    }
    #expect(conflict == .releaseRequired && !attempted)
    #expect(owners.values(for: .touchBar)[transactionBend]?.value == 8200)
}

@Test func relativeTransactionSparseMovementAndDuplicateAnchorRetire() throws {
    var state = try transaction(), owners = LegacyContinuousOwners()
    var attempts: [LegacyContinuousOwners.Update] = []
    _ = state.anchor(owners: &owners, reservedChannels: [], permits: { true })
    let first = state.movement([.x: 9000], owners: &owners, reservedChannels: [], permits: { true }) {
        attempts.append($0); return true
    }
    let second = state.movement([.y: 50], owners: &owners, reservedChannels: [], permits: { true }) {
        attempts.append($0); return true
    }
    let stationary = state.movement([:], owners: &owners, reservedChannels: [], permits: { true }) {
        attempts.append($0); return true
    }
    #expect(first == .accepted && second == .accepted && stationary == .accepted)
    #expect(attempts.map(\.target) == [transactionBend, transactionCC])
    #expect(owners.values(for: .helper).count == 2)
    #expect(state.anchor(owners: &owners, reservedChannels: [], permits: { true }) == .releaseRequired)
    #expect(state.retire() == .blocked)
}

@Test func relativeInterlockRetiresBeforeCompetingOwnerCanRestoreStaleValue() throws {
    var state = try transaction(), owners = LegacyContinuousOwners()
    _ = state.anchor(owners: &owners, reservedChannels: [], permits: { true })
    _ = state.movement([.x: 9000, .y: 50], owners: &owners, reservedChannels: [], permits: { true }, send: { _ in true })
    let takeover = owners.set(.touchBar, target: transactionBend, value: .init(10000, neutral: 8192))
    #expect(takeover == [.init(transactionCC, value: 0), .init(transactionBend, value: 8192), .init(transactionBend, value: 10000)])
    #expect(owners.values(for: .helper).isEmpty)
    #expect(owners.release(.touchBar) == [.init(transactionBend, value: 8192)])
    var attempted = false
    let stale = state.movement([.x: 9500], owners: &owners, reservedChannels: [], permits: { true }) { _ in attempted = true; return true }
    #expect(stale == .releaseRequired && !attempted)
    let clean = state.confirmCleanup(owners: &owners, genuineNeutral: true, transportClean: true)
    #expect(clean)
    #expect(state.anchor(owners: &owners, reservedChannels: [], permits: { true }) == .anchored)
}

@Test func relativeInterlockFailedCompetingCleanupNeverInstallsOrRestoresIntent() throws {
    var state = try transaction(), owners = LegacyContinuousOwners()
    _ = state.anchor(owners: &owners, reservedChannels: [], permits: { true })
    _ = state.movement([.x: 9000, .y: 50], owners: &owners, reservedChannels: [], permits: { true }, send: { _ in true })
    var attempts: [LegacyContinuousOwners.Update] = []
    let completed = owners.replaceAdmitted(.touch, values: [transactionBend: .init(10000, neutral: 8192)], permits: { true }) {
        attempts.append($0); return false
    }
    #expect(!completed && attempts == [.init(transactionCC, value: 0)])
    #expect(owners.values(for: .helper).isEmpty && owners.values(for: .touch).isEmpty)
    #expect(owners.release(.touch).isEmpty)
    #expect(state.movement([:], owners: &owners, reservedChannels: [], permits: { true }, send: { _ in false }) == .releaseRequired)
    let debt = state.confirmCleanup(owners: &owners, genuineNeutral: true, transportClean: false)
    #expect(!debt)
}

@Test func relativeInterlockDoesNotChangeAbsoluteFallbackOrUnrelatedOwner() throws {
    var owners = LegacyContinuousOwners()
    _ = owners.set(.helper, target: transactionBend, value: .init(9000, neutral: 8192))
    _ = owners.set(.touch, target: transactionBend, value: .init(10000, neutral: 8192))
    #expect(owners.release(.touch) == [.init(transactionBend, value: 9000)])
    _ = owners.release(.helper)
    var state = try transaction()
    _ = state.anchor(owners: &owners, reservedChannels: [], permits: { true })
    let unrelated = SensorDestination(.controlChange, channel: 3, number: 74)
    #expect(owners.set(.touchBar, target: unrelated, value: .init(20, neutral: 0)) == [.init(unrelated, value: 20)])
    #expect(state.movement([.x: 9000], owners: &owners, reservedChannels: [], permits: { true }, send: { _ in true }) == .accepted)
    #expect(owners.release(.helper, channel: 3).isEmpty)
    #expect(owners.values(for: .helper)[transactionBend]?.value == 9000)
    #expect(owners.release(.helper, channel: 2) == [.init(transactionBend, value: 8192)])
    #expect(owners.values(for: .touchBar)[unrelated]?.value == 20)
}

@Test func relativeInterlockLeaseCannotBeClearedOrOverwrittenByOtherToken() throws {
    var owners = LegacyContinuousOwners()
    let reserved = owners.reserveRelativeHelper(targets: [transactionBend])
    let token = try #require(reserved)
    #expect(owners.reserveRelativeHelper(targets: [transactionCC]) == nil)
    let wrong = UUID()
    let wrongFinish = owners.finishRelativeHelper(wrong, transportClean: true)
    #expect(!wrongFinish)
    let wrongSend = owners.replaceRelativeHelperAdmitted(wrong, values: [transactionBend: .init(9000, neutral: 8192)], permits: { true }, send: { _ in true })
    #expect(!wrongSend)
    #expect(owners.permitsRelativeHelper(token))
    #expect(owners.set(.helper, target: transactionBend, value: .init(9000, neutral: 8192)).isEmpty)
    #expect(!owners.permitsRelativeHelper(token))
    let dirty = owners.finishRelativeHelper(token, transportClean: false)
    #expect(!dirty)
    let clean = owners.finishRelativeHelper(token, transportClean: true)
    #expect(clean)
    #expect(owners.set(.helper, target: transactionBend, value: .init(9000, neutral: 8192)) == [.init(transactionBend, value: 9000)])
}
