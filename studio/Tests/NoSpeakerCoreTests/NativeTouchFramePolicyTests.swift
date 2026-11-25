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
