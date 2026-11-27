import Foundation
import Testing
@testable import NoSpeakerCore

private typealias Binding = NativeHelperRelativeInputBinding
private typealias Clutch = NativeHelperRelativeClutch
private let ns: Int64 = 1_000_000_000

/// Serialized fixture uses the actual transaction, arbiter and debt policy.
/// Only the CoreMIDI wire, clock and live host admission are simulated.
private final class Rig {
    let monitor = UUID(), registration = UUID()
    let surface: Clutch.Surface
    var binding: Binding
    var owners = LegacyContinuousOwners(), debt = LegacyControllerReleaseDebt()
    var transaction: NativeHelperRelativeOutputTransaction?
    var now = ns, sequence: UInt64 = 0
    var live = true, recovery = false
    var attempted: [LegacyContinuousOwners.Update] = []
    var retirements: [Bool] = []
    var neutralPlans: [Set<SensorDestination>] = []
    var delayBeforeWire = false, loseLiveBeforeWire = false
    var planTargets: Set<SensorDestination>

    init(surface: Clutch.Surface = .magicMouse, orientation: SurfaceOrientation = .vertical) throws {
        self.surface = surface
        let boundary = try #require(NativeHelperRelativeArmBoundary(source: surface, registration: registration,
            afterSequence: 0, afterAcquisitionNS: ns - 1))
        let config = try #require(NativeHelperRelativeSingleChannel(settings: .init(), enabled: [.x,.y],
            channel: 2, vibratoCC: 74, expressionCC: 11))
        binding = try #require(Binding(boundary: boundary, monitor: monitor, configuration: config, orientation: orientation))
        planTargets = config.configuration.plan.targetDestinations
    }

    func frame(x: Double? = nil, y: Double = 0.5, source: Clutch.Surface? = nil,
               registration: UUID? = nil, consistent: Bool = true) -> Clutch.SourceFrame {
        let selected = source ?? surface
        let contacts: [Clutch.Contact] = x.map { [.init(surface: selected,id:1,x:$0,y:y,contactSize:0.5)] } ?? []
        return .init(surface: selected,rawDownCount:contacts.count,sourceConsistent:consistent,contacts:contacts,
            receipt: Double(now)/1_000_000_000,nativeRegistration:registration ?? self.registration,acquisitionNS:now)
    }

    func push(x: Double? = nil, y: Double = 0.5, source: Clutch.Surface? = nil,
              missing: Bool = false, token: UUID? = nil, consistent: Bool = true) -> Binding.Result {
        now += 10_000_000; sequence += 1
        let frame = missing ? nil : self.frame(x:x,y:y,source:source,consistent:consistent)
        // Keep the binding's mutating access disjoint from host callback state.
        var candidate = binding
        let result = candidate.receive(frame,source:source ?? surface,monitor:token ?? monitor,sequence:sequence,
            clock:{ self.now },live:{ self.live },activeLeaseValid:{
                self.transaction?.hasActiveLogicalLease(owners:self.owners,reservedChannels:[]) == true
            },begin:{ plan,permit in
                guard self.transaction == nil else { return false }
                var state=NativeHelperRelativeOutputTransaction(plan:plan)
                let result=state.anchor(owners:&self.owners,reservedChannels:[],permits:{
                    permit() && !self.recovery && !NativeHelperRelativeHostPolicy.hasPendingCleanup(targets:plan.targetDestinations,debt:self.debt)
                })
                self.transaction=state
                return result == .anchored
            },move:{ values,permit in
                guard var state=self.transaction else { return false }
                var owners=self.owners
                let result=state.movement(values,owners:&owners,reservedChannels:[],permits:permit,send:{ update in
                    if self.delayBeforeWire { self.now += NativeHelperRelativeAcquisitionFence.maximumAgeNS }
                    if self.loseLiveBeforeWire { self.live = false }
                    guard permit() else { return false }
                    self.attempted.append(update); return true
                })
                self.owners=owners; self.transaction=state
                return result == .accepted
            },retire:retire)
        binding=candidate
        return result
    }

    func retire(_ neutral: Bool, _ plan: NativeHelperRelativeOutputPlan) -> Bool {
        retirements.append(neutral); neutralPlans.append(plan.targetDestinations)
        if var state=transaction {
            _=state.retire()
            let reserved=owners.relativeReservedTargets
            if !reserved.isEmpty { _=owners.release(.helper) }
            let result=NativeHelperRelativeHostPolicy.finishRetirement(transaction:&state,owners:&owners,
                reservedTargets:reserved,genuineNeutral:neutral,currentPlanTargets:plan.targetDestinations,
                debt:debt,transportReady:true,recoveryRequired:recovery)
            transaction=result.finished ? nil : state
            return result.neutralPermitted
        }
        return NativeHelperRelativeHostPolicy.permitsInitialNeutral(genuineNeutral:neutral,plannedTargets:plan.targetDestinations,
            owners:owners,debt:debt,transportReady:true,recoveryRequired:recovery)
    }

    func replaceBinding(channel: Int) throws {
        let boundary = try #require(NativeHelperRelativeArmBoundary(source:surface,registration:registration,
            afterSequence:sequence,afterAcquisitionNS:now))
        let config = try #require(NativeHelperRelativeSingleChannel(settings:.init(),enabled:[.x,.y],
            channel:channel,vibratoCC:74,expressionCC:11))
        binding = try #require(Binding(boundary:boundary,monitor:monitor,configuration:config,orientation:.horizontal))
        planTargets=config.configuration.plan.targetDestinations
    }

    func poll() -> Binding.Result {
        var candidate=binding
        let result=candidate.poll(nowNS:now,live:live,retire:retire)
        binding=candidate; return result
    }
    func close() -> Binding.Result {
        var candidate=binding
        let result=candidate.close(retire:retire)
        binding=candidate; return result
    }
}

@Test func relativeBindingUsesFrozenPlanAndSelectedOrientation() throws {
    for surface in [Clutch.Surface.trackpad,.magicMouse] {
        let r=try Rig(surface:surface)
        let foreign:Clutch.Surface = surface == .trackpad ? .magicMouse : .trackpad
        #expect(r.push(source:foreign) == .ignored)
        #expect(r.push(source:foreign,missing:true) == .ignored)
        #expect(r.push(token:UUID()) == .ignored)
        #expect(r.push(x:0.5) == .waiting)
        #expect(r.retirements.isEmpty)
        #expect(r.push() == .waiting)
        #expect(r.neutralPlans == [r.planTargets])
        #expect(r.push(x:0.5) == .anchored)
        #expect(r.attempted.isEmpty)
        #expect(r.push(x:surface == .magicMouse ? 0.25 : 0.75) == .accepted)
        let bend = r.attempted.first { $0.target.kind == .pitchBend }
        let cc = r.attempted.first { $0.target.kind == .controlChange }
        if surface == .magicMouse { #expect(bend == nil && cc?.value == 32) }
        else { #expect(bend?.value == 12288 && cc == nil) }
        #expect(r.push() == .waiting)
        #expect(r.transaction == nil && r.owners.relativeReservedTargets.isEmpty)
        #expect(r.neutralPlans.allSatisfy { $0 == r.planTargets })
    }
}

@Test func relativeBindingDirtyInitialNeutralRequiresAnotherRealLift() throws {
    let r=try Rig(surface:.trackpad)
    r.debt.beginRange(channel:2)
    #expect(r.push() == .retired)
    r.debt.completeRange(channel:2)
    #expect(r.push(x:0.5) == .waiting)
    #expect(r.transaction == nil)
    #expect(r.push() == .waiting)
    #expect(r.push(x:0.5) == .anchored)
}

@Test func relativeBindingLateWireAndPreemptionDoNotInventNeutral() throws {
    let r=try Rig(surface:.trackpad)
    _=r.push(); _=r.push(x:0.5)
    r.delayBeforeWire=true
    #expect(r.push(x:0.75) == .retired)
    #expect(r.attempted.isEmpty && r.retirements.last == false)
    r.delayBeforeWire=false
    #expect(r.push(x:0.75) == .waiting)
    #expect(r.push() == .waiting)
    #expect(r.push(x:0.5) == .anchored)
    let bend=SensorDestination(.pitchBend,channel:2)
    _=r.owners.set(.touchBar,target:bend,value:.init(9000,neutral:8192))
    #expect(r.push(x:0.5) == .retired)
    #expect(r.retirements.last == false && r.owners.values(for:.touchBar)[bend]?.value == 9000)
}

@Test func relativeBindingMissingSelectedFrameAndLiveLossClosePermanently() throws {
    for missing in [true,false] {
        let r=try Rig(surface:.trackpad)
        _=r.push(); _=r.push(x:0.5)
        if missing { #expect(r.push(missing:true) == .retired) }
        else { r.live=false; #expect(r.poll() == .retired) }
        r.live=true
        #expect(r.retirements.last == false)
        #expect(r.push() == .ignored)
        #expect(r.push(x:0.5) == .ignored)
        #expect(r.close() == .ignored)
    }
}

@Test func relativeBindingWatchdogExpiresWithoutFreshLiftAndCloseIgnoresLiveGate() throws {
    let r=try Rig(surface:.trackpad)
    _=r.push(); _=r.push(x:0.5)
    r.now += 151_000_000
    #expect(r.poll() == .retired)
    #expect(r.retirements.last == false)
    #expect(r.push(x:0.5) == .waiting)
    #expect(r.push() == .waiting)
    #expect(r.push(x:0.5) == .anchored)
    r.live=false
    #expect(r.close() == .retired)
    #expect(r.retirements.last == false)
    #expect(r.push() == .ignored)
}

@Test func relativeBindingReplacementPlanDebtDoesNotBorrowOldCleanup() throws {
    let r=try Rig(surface:.trackpad)
    _=r.push(); _=r.push(x:0.5)
    #expect(r.close() == .retired)
    r.debt.beginRange(channel:3)
    try r.replaceBinding(channel:3)
    #expect(r.push() == .retired)
    #expect(r.transaction == nil && r.owners.relativeReservedTargets.isEmpty)
    #expect(r.neutralPlans.last == r.planTargets)
    r.debt.completeRange(channel:3)
    #expect(r.push(x:0.5) == .waiting)
    #expect(r.transaction == nil)
    #expect(r.push() == .waiting)
    #expect(r.push(x:0.5) == .anchored)
    #expect(r.owners.relativeReservedTargets == r.planTargets)
}

@Test func relativeBindingLiveAdmissionLossDuringWireRetiresWithoutNewSend() throws {
    let r=try Rig(surface:.trackpad)
    _=r.push(); _=r.push(x:0.5)
    r.loseLiveBeforeWire=true
    #expect(r.push(x:0.75) == .retired)
    #expect(r.attempted.isEmpty && r.retirements.last == false)
    r.live=true; r.loseLiveBeforeWire=false
    #expect(r.push(x:0.75) == .waiting)
    #expect(r.push() == .waiting)
    #expect(r.push(x:0.5) == .anchored)
}
