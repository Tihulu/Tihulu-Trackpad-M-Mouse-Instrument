import Foundation
import Testing
@testable import NoSpeakerCore

private typealias Policy = NativeHelperRelativeHostPolicy
private let cc = SensorDestination(.controlChange, channel: 2, number: 74)
private let bend = SensorDestination(.pitchBend, channel: 2)
private let targets: Set<SensorDestination> = [cc, bend]

@Test func relativeHostInitialNeutralRequiresKnownCleanPlanAndLiveTransport() {
    var owners = LegacyContinuousOwners(), debt = LegacyControllerReleaseDebt()
    func permits(_ plan: Set<SensorDestination>? = targets, neutral: Bool = true,
                 transport: Bool = true, recovery: Bool = false) -> Bool {
        Policy.permitsInitialNeutral(genuineNeutral: neutral, plannedTargets: plan, owners: owners,
            debt: debt, transportReady: transport, recoveryRequired: recovery)
    }
    #expect(permits())
    #expect(!permits(nil) && !permits([]) && !permits(neutral: false))
    #expect(!permits(transport: false) && !permits(recovery: true))
    debt.record(.init(0xb3,74,90),neutral:0,succeeded:false)
    debt.record(.init(0xb2,71,90),neutral:0,succeeded:false)
    #expect(permits())
    debt.record(.init(0xb2,74,90),neutral:0,succeeded:false)
    #expect(!permits())
    debt.record(.init(0xb2,74,0),neutral:0,succeeded:true)
    #expect(permits())
    debt.beginRange(channel:2)
    #expect(!permits())
    debt.completeRange(channel:2)
    _ = owners.set(.helper,target:cc,value:.init(90,neutral:0))
    #expect(!permits())
    _ = owners.release(.helper)
    _ = owners.reserveRelativeHelper(targets:targets)
    #expect(!permits())
}

@Test func relativeHostDeniedAnchorRetainsPlannedDebtWithoutUnownedRelease() throws {
    let plan = try #require(NativeHelperRelativeOutputPlan(targets:[.x:bend,.y:cc]))
    for kind in 0...2 {
        var owners=LegacyContinuousOwners(), debt=LegacyControllerReleaseDebt()
        var state=NativeHelperRelativeOutputTransaction(plan:plan)
        switch kind {
        case 0: debt.record(.init(0xb2,74,90),neutral:0,succeeded:false)
        case 1: debt.record(.init(0xe2,1,70),neutral:8192,succeeded:false)
        default: debt.beginRange(channel:2)
        }
        #expect(state.anchor(owners:&owners,reservedChannels:[],permits:{false}) == .blocked)
        #expect(owners.relativeReservedTargets.isEmpty && state.cleanupTargets == targets)
        #expect(owners.release(.helper).isEmpty)
        let dirty=Policy.permitsCleanupConfirmation(plannedTargets:state.cleanupTargets,
            reservedTargets:owners.relativeReservedTargets,debt:debt,transportReady:true,recoveryRequired:false)
        #expect(!dirty)
        #expect(!state.confirmCleanup(owners:&owners,genuineNeutral:true,transportClean:dirty))
        #expect(state.anchor(owners:&owners,reservedChannels:[],permits:{true}) == .blocked)
        let clean=Policy.permitsCleanupConfirmation(plannedTargets:state.cleanupTargets,
            reservedTargets:owners.relativeReservedTargets,debt:.init(),transportReady:true,recoveryRequired:false)
        #expect(clean)
        #expect(!state.confirmCleanup(owners:&owners,genuineNeutral:false,transportClean:clean))
        #expect(state.confirmCleanup(owners:&owners,genuineNeutral:true,transportClean:clean))
        #expect(state.anchor(owners:&owners,reservedChannels:[],permits:{true}) == .anchored)
    }
}

@Test func relativeHostCleanupConfirmationIncludesReservationWithoutBroadeningSendTargets() {
    let reserved=SensorDestination(.controlChange,channel:3,number:74)
    var debt=LegacyControllerReleaseDebt()
    debt.record(.init(0xb3,74,90),neutral:0,succeeded:false)
    #expect(!Policy.permitsCleanupConfirmation(plannedTargets:targets,reservedTargets:[reserved],
        debt:debt,transportReady:true,recoveryRequired:false))
    #expect(Policy.permitsCleanupConfirmation(plannedTargets:targets,reservedTargets:[],
        debt:debt,transportReady:true,recoveryRequired:false))
    #expect(!Policy.permitsCleanupConfirmation(plannedTargets:targets,reservedTargets:[],
        debt:debt,transportReady:false,recoveryRequired:false))
    #expect(!Policy.permitsCleanupConfirmation(plannedTargets:targets,reservedTargets:[],
        debt:debt,transportReady:true,recoveryRequired:true))
}

@Test func relativeHostLogicalLeaseProbeDetectsPreemptionAndReservedChannelWithoutMutation() throws {
    let plan=try #require(NativeHelperRelativeOutputPlan(targets:[.x:bend,.y:cc]))
    var owners=LegacyContinuousOwners(), state=NativeHelperRelativeOutputTransaction(plan:plan)
    #expect(!state.hasActiveLogicalLease(owners:owners,reservedChannels:[]))
    #expect(state.anchor(owners:&owners,reservedChannels:[],permits:{true}) == .anchored)
    #expect(state.hasActiveLogicalLease(owners:owners,reservedChannels:[]))
    #expect(!state.hasActiveLogicalLease(owners:owners,reservedChannels:[2]))
    #expect(state.hasActiveLogicalLease(owners:owners,reservedChannels:[]))
    #expect(state.movement([.y:90],owners:&owners,reservedChannels:[],permits:{true},send:{_ in true}) == .accepted)
    let snapshot=owners.values(for:.helper), reservation=owners.relativeReservedTargets
    for _ in 0..<100 { #expect(state.hasActiveLogicalLease(owners:owners,reservedChannels:[])) }
    #expect(owners.values(for:.helper) == snapshot && owners.relativeReservedTargets == reservation)
    _ = owners.set(.touchBar,target:cc,value:.init(30,neutral:0))
    #expect(!state.hasActiveLogicalLease(owners:owners,reservedChannels:[]))
    #expect(owners.values(for:.helper).isEmpty && owners.values(for:.touchBar)[cc]?.value == 30)
}
