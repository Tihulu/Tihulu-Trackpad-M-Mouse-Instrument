import XCTest
@testable import NoSpeakerCore

final class AirDualHandPerformanceTests: XCTestCase {
    private func hand(_ closed: Bool) -> AirHandSample {
        func p(_ x: Double, _ y: Double) -> AirHandPoint { .init(x: x, y: y, confidence: 1) }
        return AirHandSample(thumb: p(closed ? 0.51 : 0.7, 0.5), index: p(0.5, 0.5),
                             wrist: p(0.5, 0.3), middleBase: p(0.5, 0.5))!
    }

    func testLiveChordReleasePreservesOtherSource() throws {
        var runtime = PhysicalPatchRuntime()
        let local = SensorMapping(id: "local", source: .trackpad, signal: .contact,
                                  destination: .init(.note, number: 60))
        try runtime.configure(.init(name: "Hybrid", routes: AirDualHandPerformance.routes() + [local]))
        _ = runtime.receive(source: .trackpad, x: 0.5, y: 0.5, size: 0.5, hostTime: 0, now: 0)
        XCTAssertTrue(runtime.receiveDualHand(count: 0, confidence: 1, helper: hand(false), hostTime: 0.01, now: 0.01).isEmpty)
        XCTAssertTrue(runtime.receiveDualHand(count: 1, confidence: 1, helper: hand(false), hostTime: 0.02, now: 0.02).isEmpty)
        XCTAssertTrue(runtime.receiveDualHand(count: 1, confidence: 1, helper: hand(false), hostTime: 0.16, now: 0.16).isEmpty)
        let on = runtime.receiveDualHand(count: 1, confidence: 1, helper: hand(true), hostTime: 0.18, now: 0.18)
        XCTAssertEqual(Set(on.filter { $0.value > 0 }.map { $0.destination.number }), Set([64,67]))
        let off = runtime.receiveDualHand(count: nil, confidence: 0, helper: nil, hostTime: 0.19, now: 0.19)
        XCTAssertEqual(Set(off.filter { $0.value == 0 }.map { $0.destination.number }), Set([64,67]))
        XCTAssertTrue(runtime.activeSources.contains(.trackpad))
        XCTAssertFalse(runtime.activeSources.contains(.camera))
        XCTAssertTrue(runtime.receiveDualHand(count: 1, confidence: 1, helper: hand(true), hostTime: 0.2, now: 0.2).isEmpty)
    }

    func testWatchdogReleasesChord() throws {
        var runtime = PhysicalPatchRuntime()
        try runtime.configure(.init(name: "Air", routes: AirDualHandPerformance.routes()))
        _ = runtime.receiveDualHand(count: 0, confidence: 1, helper: hand(false), hostTime: 0, now: 0)
        _ = runtime.receiveDualHand(count: 1, confidence: 1, helper: hand(false), hostTime: 0.01, now: 0.01)
        _ = runtime.receiveDualHand(count: 1, confidence: 1, helper: hand(false), hostTime: 0.15, now: 0.15)
        XCTAssertEqual(runtime.receiveDualHand(count: 1, confidence: 1, helper: hand(true), hostTime: 0.16, now: 0.16).count, 3)
        XCTAssertEqual(runtime.expire(now: 0.42).filter { $0.value == 0 }.count, 3)
        XCTAssertTrue(runtime.expire(now: 0.5).isEmpty)
    }

    func testPinchRequiresOpenAndDoesNotReplay() {
        var gate = AirPinchGate()
        XCTAssertNil(gate.update(aperture: 0.1, selectedSlot: 1))
        XCTAssertNil(gate.update(aperture: 0.5, selectedSlot: 1))
        XCTAssertEqual(gate.update(aperture: 0.1, selectedSlot: 1), 1)
        XCTAssertNil(gate.update(aperture: 0.1, selectedSlot: 2))
        XCTAssertNil(gate.update(aperture: 0.1, selectedSlot: 1))
        XCTAssertNil(gate.update(aperture: 0.5, selectedSlot: 2))
        XCTAssertEqual(gate.update(aperture: 0.1, selectedSlot: 2), 2)
    }

    func testFingerGeometry() {
        func p(_ x: Double, _ y: Double) -> AirHandPoint { .init(x: x, y: y, confidence: 1) }
        let extended = AirFingerChain(base: p(0.2,0.2), joint: p(0.2,0.4), tip: p(0.2,0.6))
        let folded = AirFingerChain(base: p(0.2,0.2), joint: p(0.2,0.4), tip: p(0.3,0.2))
        XCTAssertEqual(AirFingerCount.classify([extended,folded,extended,folded,extended]), 3)
        XCTAssertNil(AirFingerCount.classify([extended]))
    }
}
