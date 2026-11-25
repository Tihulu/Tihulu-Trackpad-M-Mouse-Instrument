import XCTest
@testable import NoSpeakerCore

final class AirCombinedHandsTests: XCTestCase {
    func testChordAndEffectsWithPartialLossAndDebugParity() throws {
        let route = AirHandsHelper.route(hand:.left,axis:.y,effect:.expression)!
        let patch = InstrumentPatch(name:"Combined",routes:AirDualHandPerformance.routes()+[route])
        var live = PhysicalPatchRuntime()
        var debug = PatchSimulation()
        try live.configure(patch)
        try debug.start(patch,now:0)
        let left = AirHandSample.debugSample(x:0.5,y:0.3,aperture:0.8)
        let open = AirHandSample.debugSample(x:0.5,y:0.5,aperture:0.8)
        let closed = AirHandSample.debugSample(x:0.5,y:0.5,aperture:0.1)
        let frames:[(Int?,AirHandSample?,AirHandSample?,Double)] = [
            (0,left,open,0),(1,left,open,0.07),(1,left,open,0.21),
            (1,left,closed,0.23),(1,left,nil,0.24),(nil,nil,nil,0.25)]
        for (count,l,r,t) in frames {
            let a = live.receiveCombinedHands(count:count,confidence:1,left:l,right:r,swapRoles:false,hostTime:t,now:t)
            let b = debug.receiveCombinedHands(count:count,confidence:1,left:l,right:r,swapRoles:false,time:t,now:t)
            XCTAssertEqual(a,b)
            if t == 0.23 { XCTAssertEqual(a.filter{$0.destination.kind == .note && $0.value > 0}.count,3) }
            if t == 0.24 {
                XCTAssertEqual(a.filter{$0.destination.kind == .note && $0.value == 0}.count,3)
                XCTAssertFalse(a.contains{$0.destination.kind == .controlChange})
                XCTAssertTrue(live.activeSources.contains(.camera))
            }
            if t == 0.25 { XCTAssertEqual(a,[.init(.init(.controlChange,number:11),value:127)]) }
        }
    }

    func testMixedDestinationAndLegacyModeValidation() {
        let named = AirHandsHelper.route(hand:.left,axis:.x,effect:.pitchBend)!
        let legacy = SensorMapping(id:"old",source:.camera,signal:.x,destination:.init(.pitchBend))
        XCTAssertFalse(InstrumentPatch(name:"Legacy conflict",routes:[named,legacy]).isValid)
        XCTAssertFalse(InstrumentPatch(name:"Mixed conflict",routes:[named,legacy]+AirDualHandPerformance.routes()).isValid)
        XCTAssertTrue(InstrumentPatch(name:"Guitar plus named",routes:[named]+AirStrumPerformance.routes(bank:AirStrumPerformance.guitarBank)).isValid)
    }
}
