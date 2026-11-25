import Foundation
import Testing
@testable import NoSpeakerCore

private func portPlan() throws -> PerformanceGroupEndpointPlan {
    try .init(profile:.init(groups:[.init(name:"A",patch:.starter),.init(name:"B",patch:.starter)]))
}
private final class PortFixture {
    var registry: [Int32:UInt32] = [:]
    var created: [UInt32] = []
    var disposed: [UInt32] = []
    var failAssignment = false
    var failDisposal = false
    var failCreateAt: Int?
    var failLookup = false
    func lookup(_ id: Int32) -> PerformanceGroupPortRegistry.Lookup {
        if failLookup { return .unavailable }
        if let handle = registry[id] { return .present(handle) }
        return .absent
    }
    func create(_ entry: PerformanceGroupEndpointPlan.Entry) -> PerformanceGroupPortRegistry.Creation {
        let handle = UInt32(created.count + 100)
        created.append(handle)
        return .init(handle:handle,succeeded:created.count != failCreateAt)
    }
    func assign(_ handle: UInt32,_ id: Int32) -> Bool {
        guard !failAssignment,registry[id] == nil else { return false }
        registry[id] = handle
        return true
    }
    func dispose(_ handle: UInt32) -> Bool {
        disposed.append(handle)
        guard !failDisposal else { return false }
        registry = registry.filter { $0.value != handle }
        return true
    }
}

@Test func groupPortsOpenAtomicallyAndReuseOnlyVerifiedExistingPlan() throws {
    let plan = try portPlan()
    let f = PortFixture()
    var ports = PerformanceGroupPortRegistry()
    try ports.open(plan,lookup:f.lookup,create:f.create,assign:f.assign,dispose:f.dispose)
    #expect(ports.registeredIDs == Set(plan.entries.map(\.id)))
    #expect(f.created.count == 2)
    try ports.open(plan,lookup:f.lookup,create:f.create,assign:f.assign,dispose:f.dispose)
    #expect(f.created.count == 2)
    f.registry.removeValue(forKey:plan.entries[0].uniqueID)
    #expect(throws: PerformanceGroupPortRegistry.Failure.verifyFailed(plan.entries[0].id)) {
        try ports.open(plan,lookup:f.lookup,create:f.create,assign:f.assign,dispose:f.dispose)
    }
    #expect(f.created.count == 2 && f.disposed.isEmpty)
}

@Test func groupPortsPreflightRejectsOccupiedOrUnknownWithoutCreating() throws {
    let plan = try portPlan()
    let f = PortFixture()
    var ports = PerformanceGroupPortRegistry()
    let id = plan.entries[1].uniqueID
    f.registry[id] = 999
    #expect(throws: PerformanceGroupPortRegistry.Failure.occupied(id)) {
        try ports.open(plan,lookup:f.lookup,create:f.create,assign:f.assign,dispose:f.dispose)
    }
    #expect(f.created.isEmpty && f.disposed.isEmpty && f.registry[id] == 999)
    f.failLookup = true
    #expect(throws: PerformanceGroupPortRegistry.Failure.lookupFailed(plan.entries[0].uniqueID)) {
        try ports.open(plan,lookup:f.lookup,create:f.create,assign:f.assign,dispose:f.dispose)
    }
    #expect(f.created.isEmpty)
}

@Test func groupPortsPartialOpenRollsBackIncludingFailedCreationHandle() throws {
    let plan = try portPlan()
    let f = PortFixture()
    f.failCreateAt = 2
    var ports = PerformanceGroupPortRegistry()
    #expect(throws: PerformanceGroupPortRegistry.Failure.createFailed(plan.entries[1].id)) {
        try ports.open(plan,lookup:f.lookup,create:f.create,assign:f.assign,dispose:f.dispose)
    }
    #expect(f.disposed == [101,100])
    #expect(f.registry.isEmpty && ports.registeredIDs.isEmpty && !ports.hasRecoveryDebt)
}

@Test func groupPortsRollbackDebtBlocksOpenUntilRetried() throws {
    let plan = try portPlan()
    let f = PortFixture()
    f.failAssignment = true
    f.failDisposal = true
    var ports = PerformanceGroupPortRegistry()
    #expect(throws: PerformanceGroupPortRegistry.Failure.assignFailed(plan.entries[0].id)) {
        try ports.open(plan,lookup:f.lookup,create:f.create,assign:f.assign,dispose:f.dispose)
    }
    #expect(ports.pendingDisposalCount == 1)
    #expect(throws: PerformanceGroupPortRegistry.Failure.recoveryRequired) {
        try ports.open(plan,lookup:f.lookup,create:f.create,assign:f.assign,dispose:f.dispose)
    }
    #expect(f.created.count == 1)
    let failed = ports.retryDisposal(f.dispose)
    #expect(!failed)
    f.failDisposal = false
    let recovered = ports.retryDisposal(f.dispose)
    #expect(recovered && !ports.hasRecoveryDebt)
}

@Test func groupPortsCloseRequiresCleanupAndRetainsFailedDisposals() throws {
    let plan = try portPlan()
    let f = PortFixture()
    var ports = PerformanceGroupPortRegistry()
    try ports.open(plan,lookup:f.lookup,create:f.create,assign:f.assign,dispose:f.dispose)
    let refused = ports.close(cleanupComplete:false,dispose:f.dispose)
    #expect(!refused && ports.registeredIDs.count == 2 && f.disposed.isEmpty)
    f.failDisposal = true
    let closed = ports.close(cleanupComplete:true,dispose:f.dispose)
    #expect(!closed && ports.registeredIDs.isEmpty && ports.pendingDisposalCount == 2)
    f.failDisposal = false
    let retried = ports.retryDisposal(f.dispose)
    #expect(retried && f.registry.isEmpty)
}
