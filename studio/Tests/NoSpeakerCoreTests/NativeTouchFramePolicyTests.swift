import Foundation
import Testing
@testable import NoSpeakerCore

@Test func nativeTouchUnknownDevicesCannotReleaseOrTriggerTrackpad() {
    for count in [Int.min,-1,0,1,32,33,Int.max] {
        for hasData in [false,true] {
            #expect(NativeTouchFramePolicy.decision(knownDevice:false,count:count,hasData:hasData) == .ignoreUnknownDevice)
        }
    }
}

@Test func nativeTouchMalformedKnownFramesReleaseWithoutDecoding() {
    for count in [Int.min,-1,0,33,Int.max] {
        for hasData in [false,true] {
            #expect(NativeTouchFramePolicy.decision(knownDevice:true,count:count,hasData:hasData) == .releaseSurface)
        }
    }
    for count in 1...32 {
        #expect(NativeTouchFramePolicy.decision(knownDevice:true,count:count,hasData:false) == .releaseSurface)
        #expect(NativeTouchFramePolicy.decision(knownDevice:true,count:count,hasData:true) == .decode(count))
    }
}


@Test func inventoryGuardNeverExpiresAStationaryContactWhileDevicePresent() {
    var guardState = NativeSurfaceInventoryGuard()
    for _ in 0..<100 {
        let verdict = guardState.observe(expected:[1,2],available:[1,2,3])
        #expect(verdict == .healthy)
    }
}

@Test func inventoryGuardRequiresTwoConsecutiveMissingObservations() {
    var guardState = NativeSurfaceInventoryGuard()
    let first = guardState.observe(expected:[1,2],available:[1])
    let recovered = guardState.observe(expected:[1,2],available:[1,2])
    let again = guardState.observe(expected:[1,2],available:[1])
    let lost = guardState.observe(expected:[1,2],available:[1])
    #expect(first == .suspect && recovered == .healthy && again == .suspect)
    #expect(lost == .lost([2]))
}

@Test func inventoryGuardDoesNotCombineDifferentDeviceMisses() {
    var guardState = NativeSurfaceInventoryGuard()
    let a = guardState.observe(expected:[1,2],available:[1])
    let b = guardState.observe(expected:[1,2],available:[2])
    let c = guardState.observe(expected:[1,2],available:[2])
    #expect(a == .suspect && b == .suspect && c == .lost([1]))
}

@Test func unavailableInventoryFailsClosedAfterThreeConsecutiveReads() {
    var guardState = NativeSurfaceInventoryGuard()
    let a = guardState.observe(expected:[1],available:nil)
    let b = guardState.observe(expected:[1],available:nil)
    let c = guardState.observe(expected:[1],available:nil)
    let recovered = guardState.observe(expected:[1],available:[1])
    #expect(a == .suspect && b == .suspect && c == .unavailable && recovered == .healthy)
}

@Test func unavailableInventoryBreaksMissingEvidenceAndEmptyMonitorResets() {
    var guardState = NativeSurfaceInventoryGuard()
    _ = guardState.observe(expected:[1],available:[])
    _ = guardState.observe(expected:[1],available:nil)
    let a = guardState.observe(expected:[1],available:[])
    let b = guardState.observe(expected:[],available:nil)
    let c = guardState.observe(expected:[1],available:[])
    #expect(a == .suspect && b == .healthy && c == .suspect)
}


@Test func nativeSurfaceAdmissionRequiresEveryExplicitRoute() {
    #expect(NativeSurfaceAdmission.missing(required:Set([1,2]),registered:Set([1])) == [2])
    #expect(NativeSurfaceAdmission.missing(required:Set([1]),registered:Set([1,2])).isEmpty)
    #expect(NativeSurfaceAdmission.missing(required:Set([1,2]),registered:Set([1,2])).isEmpty)
}

@Test func nativeSurfaceAdmissionCannotTreatUnknownInventoryAsAvailable() {
    #expect(NativeSurfaceAdmission.missing(required:Set([1,2]),registered:nil) == [1,2])
    #expect(NativeSurfaceAdmission.missing(required:Set<Int>(),registered:nil).isEmpty)
    #expect(NativeSurfaceAdmission.missing(required:Set([2]),registered:Set<Int>()) == [2])
}


@Test func inventoryReadGateRejectsConcurrentAndObsoleteLeases() throws {
    let gate=NativeInventoryReadGate()
    let first=try #require(gate.tryBegin())
    #expect(gate.tryBegin()==nil)
    gate.finish(first)
    let second=try #require(gate.tryBegin())
    gate.finish(first)
    #expect(gate.tryBegin()==nil)
    gate.finish(second)
    #expect(gate.tryBegin() != nil)
}

@Test func inventoryResultSlotsDoNotCarryRetiredMonitorEvidence() {
    let old=NativeInventoryResultSlot<Int>()
    let current=NativeInventoryResultSlot<Int>()
    old.publish(1)
    #expect(current.take()==nil)
    current.publish(2)
    #expect(current.take()==2)
    #expect(current.take()==nil)
    old.publish(3)
    #expect(current.take()==nil)
}

@Test func inventoryPollingTreatsStalledWorkerAsUnavailableWithoutWaiting() {
    let slot=NativeInventoryResultSlot<Set<UInt64>>()
    var evidence=NativeSurfaceInventoryGuard()
    let a=evidence.observe(expected:[1],available:slot.take())
    let b=evidence.observe(expected:[1],available:slot.take())
    let c=evidence.observe(expected:[1],available:slot.take())
    #expect(a == .suspect && b == .suspect && c == .unavailable)
}

@Test func mixedUnavailableAndMissingInventoryCannotKeepLostDeviceAlive() {
    for startMissing in [true,false] {
        var evidence=NativeSurfaceInventoryGuard()
        for index in 0..<4 {
            let missing=(index%2==0)==startMissing
            let available:Set<UInt64>? = missing ? [1] : nil
            let verdict=evidence.observe(expected:[1,2],available:available)
            #expect(verdict == (index==3 ? .unavailable : .suspect))
        }
    }
}

@Test func positivePerDeviceEvidenceResetsMixedInventoryBudget() {
    var evidence=NativeSurfaceInventoryGuard()
    for _ in 0..<20 {
        #expect(evidence.observe(expected:[1,2],available:nil) == .suspect)
        #expect(evidence.observe(expected:[1,2],available:[1]) == .suspect)
        #expect(evidence.observe(expected:[1,2],available:[1,2]) == .healthy)
    }
}

@Test func nativeSurfaceInventoryRefusesDuplicateIdentityRatherThanCollapsingIt() {
    #expect(NativeSurfaceAdmission.uniqueInventory([1,2]) == Set([UInt64(1),2]))
    #expect(NativeSurfaceAdmission.uniqueInventory([1,1]) == nil)
    #expect(NativeSurfaceAdmission.uniqueInventory(Array(0...64).map(UInt64.init)) == nil)
    #expect(NativeSurfaceAdmission.uniqueInventory([]) == Set<UInt64>())
}

@Test func nativeSurfaceRegistrationFenceRejectsMissingChangedAndDuplicateTokens() {
    let a=UUID(), b=UUID(), c=UUID()
    #expect(NativeSurfaceAdmission.matchesRegistrations(required:["a":a],current:["a":a,"b":b]))
    #expect(!NativeSurfaceAdmission.matchesRegistrations(required:["a":a,"b":b],current:["a":a]))
    #expect(!NativeSurfaceAdmission.matchesRegistrations(required:["a":a,"b":b],current:["a":a,"b":c]))
    #expect(!NativeSurfaceAdmission.matchesRegistrations(required:["a":a,"b":a],current:["a":a,"b":a]))
    #expect(!NativeSurfaceAdmission.matchesRegistrations(required:[:],current:["a":a]))
}
