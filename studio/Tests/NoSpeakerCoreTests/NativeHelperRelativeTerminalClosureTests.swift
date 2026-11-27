import Testing
@testable import NoSpeakerCore

private typealias Transaction = NativeHelperRelativeOutputTransaction
private typealias Policy = NativeHelperRelativeHostPolicy

@Test(arguments: Array(0..<16))
func relativeTerminalClosureDisposesOnlyCleanRetiredLease(channel: Int) throws {
    let cc = SensorDestination(.controlChange, channel: channel, number: 74)
    let unrelated = SensorDestination(.pitchBend, channel: (channel+1)%16)
    let plan = try #require(NativeHelperRelativeOutputPlan(targets:[.y:cc]))
    var owners = LegacyContinuousOwners(), transaction = Transaction(plan:plan)
    let initial = transaction.anchor(owners:&owners,reservedChannels:[],permits:{true})
    #expect(initial == .anchored)
    let moved = transaction.movement([.y:90],owners:&owners,reservedChannels:[],permits:{true},send:{_ in true})
    #expect(moved == .accepted)
    _ = owners.set(.touchBar,target:unrelated,value:.init(9000,neutral:8192))
    _ = transaction.retire()
    let reserved = owners.relativeReservedTargets
    let release = owners.release(.helper)
    #expect(release == [.init(cc,value:0)])
    let closed = Policy.finishTerminalClosure(transaction:&transaction,owners:&owners,reservedTargets:reserved,
        debt:.init(),transportReady:true,recoveryRequired:false)
    #expect(closed && owners.relativeReservedTargets.isEmpty)
    #expect(owners.values(for:.touchBar)[unrelated]?.value == 9000)
    let replay = transaction.anchor(owners:&owners,reservedChannels:[],permits:{true})
    #expect(replay == .blocked)
    _ = transaction.retire()
    let neutral = transaction.confirmCleanup(owners:&owners,genuineNeutral:true,transportClean:true)
    #expect(!neutral)
    let absolute = owners.set(.helper,target:cc,value:.init(45,neutral:0))
    #expect(absolute == [.init(cc,value:45)])
}

@Test(arguments: Array(0..<16))
func relativeTerminalClosureDirtyDebtRetainsReservationAndCannotRearm(channel: Int) throws {
    let cc = SensorDestination(.controlChange,channel:channel,number:74)
    let bend = SensorDestination(.pitchBend,channel:channel)
    let plan = try #require(NativeHelperRelativeOutputPlan(targets:[.x:bend,.y:cc]))
    for kind in 0..<5 {
        var owners = LegacyContinuousOwners(), transaction = Transaction(plan:plan), debt = LegacyControllerReleaseDebt()
        let started = transaction.anchor(owners:&owners,reservedChannels:[],permits:{true})
        #expect(started == .anchored)
        let moved = transaction.movement([.y:90],owners:&owners,reservedChannels:[],permits:{true},send:{_ in true})
        #expect(moved == .accepted)
        _ = transaction.retire()
        let reserved = owners.relativeReservedTargets
        _ = owners.release(.helper)
        switch kind {
        case 0: debt.record(.init(0xb0|channel,74,0),neutral:0,succeeded:false)
        case 1: debt.record(.init(0xe0|channel,0,64),neutral:8192,succeeded:false)
        case 2: debt.beginRange(channel:channel)
        default: break
        }
        let failed = Policy.finishTerminalClosure(transaction:&transaction,owners:&owners,reservedTargets:reserved,
            debt:debt,transportReady:kind != 3,recoveryRequired:kind == 4)
        #expect(!failed && owners.relativeReservedTargets == reserved)
        _ = transaction.retire()
        let falseNeutral = transaction.confirmCleanup(owners:&owners,genuineNeutral:true,transportClean:true)
        #expect(!falseNeutral)
        let blocked = transaction.anchor(owners:&owners,reservedChannels:[],permits:{true})
        #expect(blocked == .blocked)
        let absolute = owners.set(.helper,target:cc,value:.init(45,neutral:0))
        #expect(absolute.isEmpty)
        let retry = Policy.finishTerminalClosure(transaction:&transaction,owners:&owners,reservedTargets:reserved,
            debt:.init(),transportReady:true,recoveryRequired:false)
        #expect(retry && owners.relativeReservedTargets.isEmpty)
        let replay = transaction.anchor(owners:&owners,reservedChannels:[],permits:{true})
        #expect(replay == .blocked)
    }
}

@Test func relativeTerminalClosureRejectsActiveAndUnreleasedIntent() throws {
    let cc = SensorDestination(.controlChange,channel:2,number:74)
    let plan = try #require(NativeHelperRelativeOutputPlan(targets:[.y:cc]))
    var owners = LegacyContinuousOwners(), transaction = Transaction(plan:plan)
    let start = transaction.anchor(owners:&owners,reservedChannels:[],permits:{true})
    #expect(start == .anchored)
    let premature = transaction.confirmTerminalClosure(owners:&owners,transportClean:true)
    #expect(!premature)
    let moved = transaction.movement([.y:80],owners:&owners,reservedChannels:[],permits:{true},send:{_ in true})
    #expect(moved == .accepted)
    _ = transaction.retire()
    let unreleased = transaction.confirmTerminalClosure(owners:&owners,transportClean:true)
    #expect(!unreleased)
    #expect(owners.values(for:.helper)[cc]?.value == 80)
    _ = owners.release(.helper)
    let closed = transaction.confirmTerminalClosure(owners:&owners,transportClean:true)
    #expect(closed)
}

@Test func relativeTerminalClosureDeniedAnchorStillChecksPlanDebt() throws {
    let cc = SensorDestination(.controlChange,channel:2,number:74)
    let plan = try #require(NativeHelperRelativeOutputPlan(targets:[.y:cc]))
    var owners = LegacyContinuousOwners(), transaction = Transaction(plan:plan), debt = LegacyControllerReleaseDebt()
    debt.beginRange(channel:2)
    let denied = transaction.anchor(owners:&owners,reservedChannels:[],permits:{false})
    #expect(denied == .blocked && owners.relativeReservedTargets.isEmpty)
    let dirty = Policy.finishTerminalClosure(transaction:&transaction,owners:&owners,reservedTargets:[],
        debt:debt,transportReady:true,recoveryRequired:false)
    #expect(!dirty)
    #expect(owners.release(.helper).isEmpty)
    debt.completeRange(channel:2)
    let clean = Policy.finishTerminalClosure(transaction:&transaction,owners:&owners,reservedTargets:[],
        debt:debt,transportReady:true,recoveryRequired:false)
    #expect(clean)
    let later = transaction.anchor(owners:&owners,reservedChannels:[],permits:{true})
    #expect(later == .blocked)
}

@Test func relativeTerminalClosurePreservesUnrelatedDebtAndPersistentGain() throws {
    let gain = SensorDestination(.controlChange,channel:2,number:11)
    let plan = try #require(NativeHelperRelativeOutputPlan(targets:[.contactSize:gain]))
    var owners = LegacyContinuousOwners(), transaction = Transaction(plan:plan), debt = LegacyControllerReleaseDebt()
    let start = transaction.anchor(owners:&owners,reservedChannels:[],permits:{true})
    #expect(start == .anchored)
    let moved = transaction.movement([.contactSize:80],owners:&owners,reservedChannels:[],permits:{true},send:{_ in true})
    #expect(moved == .accepted)
    debt.record(.init(0xb3,74,90),neutral:0,succeeded:false)
    let pending = debt.pending
    _ = transaction.retire()
    let reserved = owners.relativeReservedTargets
    #expect(owners.release(.helper).isEmpty)
    let closed = Policy.finishTerminalClosure(transaction:&transaction,owners:&owners,reservedTargets:reserved,
        debt:debt,transportReady:true,recoveryRequired:false)
    #expect(closed && owners.relativeReservedTargets.isEmpty)
    #expect(debt.pending == pending && !debt.isEmpty)
}

@Test func relativeTerminalClosureCannotDisposeForeignReservation() throws {
    let cc = SensorDestination(.controlChange,channel:2,number:74)
    let plan = try #require(NativeHelperRelativeOutputPlan(targets:[.y:cc]))
    var owners = LegacyContinuousOwners(), transaction = Transaction(plan:plan)
    let start = transaction.anchor(owners:&owners,reservedChannels:[],permits:{true})
    #expect(start == .anchored)
    _ = transaction.retire()
    // Simulate owner replacement: the stale transaction's token is no longer
    // the reservation holder. Finishing it must not erase the new lease.
    owners = LegacyContinuousOwners()
    let reservation = owners.reserveRelativeHelper(targets:[cc])
    let foreign = try #require(reservation)
    let reserved = owners.relativeReservedTargets
    let closed = Policy.finishTerminalClosure(transaction:&transaction,owners:&owners,
        reservedTargets:reserved,debt:.init(),transportReady:true,recoveryRequired:false)
    #expect(!closed && owners.permitsRelativeHelper(foreign))
}

@Test func relativeTerminalClosureDeniedAnchorCannotClaimForeignReservation() throws {
    let cc = SensorDestination(.controlChange,channel:2,number:74)
    let plan = try #require(NativeHelperRelativeOutputPlan(targets:[.y:cc]))
    var owners = LegacyContinuousOwners(), transaction = Transaction(plan:plan)
    let reservation = owners.reserveRelativeHelper(targets:[cc])
    let foreign = try #require(reservation)
    let denied = transaction.anchor(owners:&owners,reservedChannels:[],permits:{true})
    #expect(denied == .blocked)
    let reserved = owners.relativeReservedTargets
    let closed = Policy.finishTerminalClosure(transaction:&transaction,owners:&owners,
        reservedTargets:reserved,debt:.init(),transportReady:true,recoveryRequired:false)
    #expect(!closed && owners.permitsRelativeHelper(foreign))
}
