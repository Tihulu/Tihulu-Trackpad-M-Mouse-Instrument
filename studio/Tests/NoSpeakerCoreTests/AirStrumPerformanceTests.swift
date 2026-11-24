import XCTest
@testable import NoSpeakerCore

final class AirStrumPerformanceTests: XCTestCase {
    func testLiveAndDebugStringPulsesAndExpiry() throws {
        let patch = InstrumentPatch(name:"Guitar",routes:AirStrumPerformance.routes(bank:AirStrumPerformance.guitarBank))
        var live = PhysicalPatchRuntime()
        var debug = PatchSimulation()
        try live.configure(patch)
        try debug.start(patch,now:0)
        let frames: [(Int,Double,Double,Double)] = [(0,0.8,0,0),(1,0.8,0,0.01),(1,0.8,0,0.15),
            (1,0.1,0,0.17),(1,0.1,1,0.22)]
        for (count,aperture,x,time) in frames {
            let hand = AirHandSample.debugSample(x:x,y:0.5,aperture:aperture)
            let a = live.receiveDualHand(count:count,confidence:1,helper:hand,hostTime:time,now:time)
            let b = debug.receiveDualHand(count:count,confidence:1,helper:hand,time:time,now:time)
            XCTAssertEqual(a,b)
            if time == 0.22 {
                XCTAssertEqual(a.map { $0.destination.number },AirStrumPerformance.guitarBank[0])
                XCTAssertTrue(a.allSatisfy { $0.value > 0 })
            } else { XCTAssertTrue(a.isEmpty) }
        }
        let off = live.expire(now:0.35)
        XCTAssertEqual(off,debug.expireDualHand(now:0.35))
        XCTAssertEqual(off.filter { $0.value == 0 }.count,6)
        XCTAssertTrue(live.expire(now:0.36).isEmpty)
    }
    func testInvalidMixAndMalformedBank() {
        let routes = AirStrumPerformance.routes(bank:AirStrumPerformance.threeCourseBank)
        XCTAssertEqual(routes.count,15)
        XCTAssertFalse(InstrumentPatch(name:"Mixed",routes:routes+AirDualHandPerformance.routes()).isValid)
        XCTAssertTrue(AirStrumPerformance.routes(bank:[[0]]).isEmpty)
        XCTAssertTrue(AirStrumPerformance.routes(bank:AirStrumPerformance.guitarBank,channel:16).isEmpty)
    }
    func testSharedNoteSurvivesCameraLoss() throws {
        let local = SensorMapping(id:"local",source:.trackpad,signal:.contact,destination:.init(.note,number:48))
        var live = PhysicalPatchRuntime()
        try live.configure(.init(name:"Hybrid",routes:AirStrumPerformance.routes(bank:AirStrumPerformance.threeCourseBank)+[local]))
        _ = live.receive(source:.trackpad,x:0.5,y:0.5,size:0.5,hostTime:0,now:0)
        for (count,aperture,x,time) in [(0,0.8,0.0,0.01),(1,0.8,0.0,0.02),(1,0.8,0.0,0.16),(1,0.1,0.0,0.18)] {
            _ = live.receiveDualHand(count:count,confidence:1,helper:AirHandSample.debugSample(x:x,y:0.5,aperture:aperture),hostTime:time,now:time)
        }
        let on = live.receiveDualHand(count:1,confidence:1,helper:AirHandSample.debugSample(x:1,y:0.5,aperture:0.1),hostTime:0.23,now:0.23)
        XCTAssertEqual(on.map { $0.destination.number },[55,60])
        XCTAssertEqual(live.releaseCamera().map { $0.destination.number }.sorted(),[55,60])
        XCTAssertTrue(live.activeSources.contains(.trackpad))
    }
}
