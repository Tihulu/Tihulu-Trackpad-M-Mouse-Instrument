import XCTest
@testable import NoSpeakerCore

final class AirHelperPerformanceTests: XCTestCase {
    func testIndependentHelperControlsMatchLiveAndDebug() throws {
        let patch = InstrumentPatch(name: "Air effects", routes: AirDualHandPerformance.routes() + AirDualHandPerformance.helperRoutes())
        var live = PhysicalPatchRuntime()
        var debug = PatchSimulation()
        try live.configure(patch)
        try debug.start(patch, now: 0)
        let frames: [(Int?, Double, Double)] = [
            (0,0.8,0), (1,0.8,0.01), (1,0.8,0.16), (1,0.1,0.18),
            (1,0.8,0.20), (1,0.8,0.22), (nil,0.8,0.24)
        ]
        for (count, aperture, time) in frames {
            let hand = AirHandSample.debugSample(x: 0.75, y: 0.6, aperture: aperture)
            let a = live.receiveDualHand(count: count, confidence: 1, helper: hand, hostTime: time, now: time)
            let b = debug.receiveDualHand(count: count, confidence: 1, helper: hand, time: time, now: time)
            XCTAssertEqual(a,b)
            let notes = a.filter { $0.destination.kind == .note }
            if time == 0.16 {
                XCTAssertTrue(notes.isEmpty)
                XCTAssertEqual(a.count,3)
            }
            if time == 0.18 { XCTAssertEqual(notes.filter { $0.value > 0 }.count,3) }
            if time == 0.20 {
                XCTAssertEqual(notes.filter { $0.value == 0 }.count,3)
                XCTAssertTrue(live.activeSources.contains(.camera))
            }
            if count == nil {
                XCTAssertFalse(live.activeSources.contains(.camera))
                XCTAssertTrue(notes.isEmpty)
                XCTAssertTrue(a.contains(.init(.init(.pitchBend),value:8192)))
                XCTAssertTrue(a.contains(.init(.init(.controlChange,number:11),value:127)))
                XCTAssertTrue(a.contains(.init(.init(.controlChange,number:74),value:0)))
            }
        }
    }

    func testFreeAxisCannotTriggerNotesInDualMode() {
        let axis = SensorMapping(id: "axis-note", source: .camera, signal: .x, destination: .init(.note,number:70))
        XCTAssertTrue(InstrumentPatch(name: "Legacy", routes: [axis]).isValid)
        XCTAssertFalse(InstrumentPatch(name: "Dual", routes: AirDualHandPerformance.routes() + [axis]).isValid)
        XCTAssertTrue(InstrumentPatch(name: "Dual effects", routes: AirDualHandPerformance.routes() + AirDualHandPerformance.helperRoutes()).isValid)
        XCTAssertTrue(AirDualHandPerformance.helperRoutes(channel: 16).isEmpty)
    }

    func testWatchdogRestoresSharedControllerOwner() throws {
        let shared = SensorMapping(id:"local-bend",source:.trackpad,signal:.x,destination:.init(.pitchBend),priority:-1)
        let patch = InstrumentPatch(name:"Hybrid",routes:AirDualHandPerformance.routes() + AirDualHandPerformance.helperRoutes() + [shared])
        var live = PhysicalPatchRuntime()
        try live.configure(patch)
        _ = live.receive(source:.trackpad,x:0.25,y:0.5,size:0.5,hostTime:0,now:0)
        let hand = AirHandSample.debugSample(x:0.75,y:0.6,aperture:0.8)
        _ = live.receiveDualHand(count:0,confidence:1,helper:hand,hostTime:0.01,now:0.01)
        _ = live.receiveDualHand(count:1,confidence:1,helper:hand,hostTime:0.02,now:0.02)
        _ = live.receiveDualHand(count:1,confidence:1,helper:hand,hostTime:0.16,now:0.16)
        _ = live.receive(source:.trackpad,x:0.25,y:0.5,size:0.5,hostTime:0.3,now:0.3)
        let release = live.expire(now:0.42)
        XCTAssertTrue(release.contains(.init(.init(.pitchBend),value:4096)))
        XCTAssertTrue(live.activeSources.contains(.trackpad))
        XCTAssertFalse(live.activeSources.contains(.camera))
    }
}
