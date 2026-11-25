import XCTest
@testable import NoSpeakerCore

final class AirDualDebugParityTests: XCTestCase {
    func testLiveAndDebugFramesHaveIdenticalCommands() throws {
        let patch = InstrumentPatch(name: "Dual", routes: AirDualHandPerformance.routes())
        var live = PhysicalPatchRuntime()
        var debug = PatchSimulation()
        try live.configure(patch)
        try debug.start(patch, now: 0)
        XCTAssertTrue(debug.hasDualCamera)
        XCTAssertTrue(debug.inputs.isEmpty)
        XCTAssertTrue(debug.running)
        let frames: [(Int, Double, Double)] = [
            (0,0.8,0), (1,0.8,0.01), (1,0.8,0.16), (1,0.1,0.18),
            (2,0.1,0.20), (2,0.1,0.34), (2,0.8,0.35), (2,0.1,0.36)
        ]
        for (count, aperture, time) in frames {
            let hand = AirHandSample.debugSample(x: 0.5,y: 0.5,aperture: aperture)
            let a = live.receiveDualHand(count: count, confidence: 1, helper: hand, hostTime: time, now: time)
            let b = debug.receiveDualHand(count: count, confidence: 1, helper: hand, time: time, now: time)
            XCTAssertEqual(a,b)
            if time == 0.18 || time == 0.36 { XCTAssertEqual(b.filter { $0.value > 0 }.count,3) }
            if time == 0.20 || time == 0.34 { XCTAssertNil(debug.airSoundingSlot) }
        }
        XCTAssertEqual(live.expire(now: 0.62),debug.expireDualHand(now: 0.62))
        XCTAssertTrue(debug.running)
        XCTAssertTrue(debug.stop().isEmpty)
        XCTAssertFalse(debug.running)
    }

    func testPendingChordCannotPlayPreviousSelection() {
        var engine = AirDualHandPerformance()
        let open = AirHandSample.debugSample(x: 0.5,y: 0.5,aperture: 0.8)
        let closed = AirHandSample.debugSample(x: 0.5,y: 0.5,aperture: 0.1)
        _ = engine.receive(count: 0, confidence: 1, helper: open, time: 0, now: 0)
        _ = engine.receive(count: 1, confidence: 1, helper: open, time: 0.01, now: 0.01)
        _ = engine.receive(count: 1, confidence: 1, helper: open, time: 0.15, now: 0.15)
        XCTAssertNil(engine.receive(count: 2, confidence: 1, helper: closed, time: 0.16, now: 0.16))
        XCTAssertNil(engine.receive(count: 2, confidence: 1, helper: closed, time: 0.30, now: 0.30))
    }

    func testDebugRejectsMalformedCoordinates() {
        XCTAssertNil(AirHandSample.debugSample(x: .nan,y: 0,aperture: 0))
        XCTAssertNil(AirHandSample.debugSample(x: 0,y: 0,aperture: 1.01))
    }

    func testTrackingLossDoesNotStopDebugSession() throws {
        var debug = PatchSimulation()
        try debug.start(.init(name: "Air", routes: AirDualHandPerformance.routes()), now: 0)
        let open = AirHandSample.debugSample(x: 0.5,y: 0.5,aperture: 0.8)
        let closed = AirHandSample.debugSample(x: 0.5,y: 0.5,aperture: 0.1)
        _ = debug.receiveDualHand(count: 0, confidence: 1, helper: open, time: 0, now: 0)
        _ = debug.receiveDualHand(count: 1, confidence: 1, helper: open, time: 0.01, now: 0.01)
        _ = debug.receiveDualHand(count: 1, confidence: 1, helper: open, time: 0.15, now: 0.15)
        XCTAssertEqual(debug.receiveDualHand(count: 1, confidence: 1, helper: closed, time: 0.17, now: 0.17).count,3)
        XCTAssertEqual(debug.releaseDualHand().filter { $0.value == 0 }.count,3)
        XCTAssertTrue(debug.running)
        XCTAssertTrue(debug.receiveDualHand(count: 1, confidence: 1, helper: closed, time: 0.19, now: 0.19).isEmpty)
        XCTAssertTrue(debug.disconnect(.camera).isEmpty)
        XCTAssertFalse(debug.running)
    }
}
