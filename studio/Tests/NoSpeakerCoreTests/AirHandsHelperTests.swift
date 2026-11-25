import XCTest
@testable import NoSpeakerCore

final class AirHandsHelperTests: XCTestCase {
    func testIndependentHandLossAndLiveDebugParity() throws {
        let l = AirHandsHelper.route(hand:.left,axis:.x,effect:.pitchBend)!
        let r = AirHandsHelper.route(hand:.right,axis:.y,effect:.expression)!
        let patch = InstrumentPatch(name:"Helper",routes:[l,r])
        var live = PhysicalPatchRuntime()
        var debug = PatchSimulation()
        try live.configure(patch)
        try debug.start(patch,now:0)
        XCTAssertTrue(debug.hasHelperHands)
        XCTAssertTrue(debug.inputs.isEmpty)
        let hand = AirHandSample.debugSample(x:0.8,y:0.3,aperture:0.8)
        for (left,right,time) in [(hand,hand,0.0),(hand,hand,0.07),(nil,hand,0.14),(nil,nil,0.21)] {
            let a = live.receiveHelperHands(left:left,right:right,hostTime:time,now:time)
            let b = debug.receiveHelperHands(left:left,right:right,time:time,now:time)
            XCTAssertEqual(a,b)
            if time == 0.07 { XCTAssertEqual(a.count,2) }
            if time == 0.14 { XCTAssertEqual(a,[.init(.init(.pitchBend),value:8192)]) }
            if time == 0.21 { XCTAssertEqual(a,[.init(.init(.controlChange,number:11),value:127)]) }
        }
    }

    func testPinchPedalRearmAndWatchdog() throws {
        let route = AirHandsHelper.route(hand:.left,axis:.pinch,effect:.sustain)!
        var live = PhysicalPatchRuntime()
        try live.configure(.init(name:"Pedal",routes:[route]))
        let closed = AirHandSample.debugSample(x:0.5,y:0.5,aperture:0.1)
        let open = AirHandSample.debugSample(x:0.5,y:0.5,aperture:0.8)
        XCTAssertTrue(live.receiveHelperHands(left:closed,right:nil,hostTime:0,now:0).isEmpty)
        XCTAssertTrue(live.receiveHelperHands(left:closed,right:nil,hostTime:0.07,now:0.07).isEmpty)
        _ = live.receiveHelperHands(left:open,right:nil,hostTime:0.14,now:0.14)
        XCTAssertEqual(live.receiveHelperHands(left:closed,right:nil,hostTime:0.21,now:0.21),[.init(.init(.sustain),value:127)])
        XCTAssertEqual(live.expire(now:0.47),[.init(.init(.sustain),value:0)])
        XCTAssertTrue(live.expire(now:0.5).isEmpty)
        XCTAssertTrue(live.receiveHelperHands(left:closed,right:nil,hostTime:0.51,now:0.51).isEmpty)
    }

    func testTogglePedalNeedsNewPinchAndClearsOnLoss() throws {
        var live = PhysicalPatchRuntime()
        let route = AirHandsHelper.route(hand:.left,axis:.toggle,effect:.sustain)!
        try live.configure(.init(name:"Toggle",routes:[route]))
        let open = AirHandSample.debugSample(x:0.5,y:0.5,aperture:0.8)
        let closed = AirHandSample.debugSample(x:0.5,y:0.5,aperture:0.1)
        func frame(_ hand:AirHandSample?,_ t:Double)->[SensorCommand] {
            live.receiveHelperHands(left:hand,right:nil,hostTime:t,now:t)
        }
        _ = frame(open,0); _ = frame(open,0.07)
        XCTAssertEqual(frame(closed,0.14),[.init(.init(.sustain),value:127)])
        XCTAssertTrue(frame(closed,0.21).isEmpty)
        XCTAssertTrue(frame(open,0.28).isEmpty)
        XCTAssertEqual(frame(closed,0.35),[.init(.init(.sustain),value:0)])
        _ = frame(open,0.42)
        XCTAssertEqual(frame(closed,0.49),[.init(.init(.sustain),value:127)])
        XCTAssertEqual(frame(nil,0.56),[.init(.init(.sustain),value:0)])
        XCTAssertTrue(frame(closed,0.63).isEmpty)
        XCTAssertTrue(frame(closed,0.70).isEmpty)
    }

    func testSharedCCPedalTransfersWithoutOffGlitch() throws {
        let l = AirHandsHelper.route(hand:.left,axis:.pinch,effect:.sostenuto)!
        let r = AirHandsHelper.route(hand:.right,axis:.pinch,effect:.sostenuto)!
        var live = PhysicalPatchRuntime()
        try live.configure(.init(name:"Both",routes:[l,r]))
        let open = AirHandSample.debugSample(x:0.5,y:0.5,aperture:0.8)
        let closed = AirHandSample.debugSample(x:0.5,y:0.5,aperture:0.1)
        func frame(_ a:AirHandSample?,_ b:AirHandSample?,_ t:Double)->[SensorCommand] {
            live.receiveHelperHands(left:a,right:b,hostTime:t,now:t)
        }
        _ = frame(open,open,0); _ = frame(open,open,0.07)
        XCTAssertEqual(frame(closed,open,0.14),[.init(.init(.controlChange,number:66),value:127)])
        XCTAssertTrue(frame(nil,closed,0.21).isEmpty)
        XCTAssertEqual(frame(nil,open,0.28),[.init(.init(.controlChange,number:66),value:0)])
        let bad = SensorMapping(id:"analog",source:.trackpad,signal:.x,destination:.init(.controlChange,number:66))
        XCTAssertFalse(InstrumentPatch(name:"Bad",routes:[l,bad]).isValid)
    }

    func testExcursionAndReservedCCValidation() {
        let bend = AirHandsHelper.configuredRoute(hand:.left,axis:.x,effect:.pitchBend,channel:3,excursion:0.5,smoothingMS:40)
        XCTAssertEqual(bend?.destination.channel,3)
        XCTAssertEqual(bend?.response?.minimum,0.25)
        XCTAssertEqual(bend?.response?.maximum,0.75)
        XCTAssertEqual(bend?.response?.smoothingMS,40)
        XCTAssertNil(AirHandsHelper.configuredRoute(hand:.left,axis:.x,effect:.pitchBend,channel:0,excursion:.nan,smoothingMS:0))
        for cc in [0,6,32,38,64,65,66,67,69,96,97,98,99,100,101,120] {
            XCTAssertNil(AirHandsHelper.configuredRoute(hand:.left,axis:.x,effect:.customCC,channel:0,excursion:1,smoothingMS:0,customCC:cc))
        }
        XCTAssertNotNil(AirHandsHelper.configuredRoute(hand:.right,axis:.y,effect:.customCC,channel:0,excursion:1,smoothingMS:0,customCC:12))
        for preset in AirHandsHelper.Preset.allCases {
            XCTAssertEqual(preset.routes(channel:2).count,2)
            XCTAssertTrue(InstrumentPatch(name:preset.title,routes:preset.routes(channel:2)).isValid)
        }
    }

    func testValidationAndOtherSourceOwnership() throws {
        XCTAssertNil(AirHandsHelper.route(hand:.left,axis:.x,effect:.sustain))
        let helper = AirHandsHelper.route(hand:.left,axis:.pinch,effect:.sustain)!
        let local = SensorMapping(id:"local",source:.trackpad,signal:.contact,destination:.init(.sustain))
        XCTAssertTrue(InstrumentPatch(name:"Combined",routes:[helper]+AirDualHandPerformance.routes()).isValid)
        var live = PhysicalPatchRuntime()
        try live.configure(.init(name:"Hybrid",routes:[helper,local]))
        _ = live.receive(source:.trackpad,x:0.5,y:0.5,size:0.5,hostTime:0,now:0)
        let open = AirHandSample.debugSample(x:0.5,y:0.5,aperture:0.8)
        let closed = AirHandSample.debugSample(x:0.5,y:0.5,aperture:0.1)
        _ = live.receiveHelperHands(left:open,right:nil,hostTime:0.01,now:0.01)
        _ = live.receiveHelperHands(left:open,right:nil,hostTime:0.08,now:0.08)
        XCTAssertTrue(live.receiveHelperHands(left:closed,right:nil,hostTime:0.15,now:0.15).isEmpty)
        XCTAssertTrue(live.releaseCamera().isEmpty)
        XCTAssertTrue(live.activeSources.contains(.trackpad))
        XCTAssertEqual(live.receive(source:.trackpad,x:nil,y:nil,size:nil,hostTime:0.16,now:0.16),[.init(.init(.sustain),value:0)])
    }
}
