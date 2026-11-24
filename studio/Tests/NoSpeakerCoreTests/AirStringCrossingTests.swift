import XCTest
@testable import NoSpeakerCore

final class AirStringCrossingTests: XCTestCase {
    func testFastStrokePreservesStringOrderBothWays() {
        var d = AirStringCrossing()!
        XCTAssertTrue(d.observe(position:0,time:0).isEmpty)
        XCTAssertEqual(d.observe(position:1,time:0.1).map(\.string),[0,1,2])
        XCTAssertEqual(d.observe(position:0,time:0.2).map(\.string),[2,1,0])
    }

    func testHysteresisAndLossNeverInventStroke() {
        var d = AirStringCrossing()!
        _ = d.observe(position:0.2,time:0)
        XCTAssertTrue(d.observe(position:0.26,time:0.01).isEmpty)
        XCTAssertTrue(d.observe(position:0.24,time:0.02).isEmpty)
        XCTAssertEqual(d.observe(position:0.29,time:0.03).map(\.string),[0])
        XCTAssertTrue(d.observe(position:nil,time:0.04).isEmpty)
        XCTAssertTrue(d.observe(position:0.9,time:0.05).isEmpty)
        XCTAssertTrue(d.observe(position:0.1,time:0.4).isEmpty)
        XCTAssertTrue(d.observe(position:0.9,time:0.4).isEmpty)
    }

    func testInvalidSettingsAndVelocityBounds() {
        XCTAssertNil(AirStringCrossing(stringCount:0))
        XCTAssertNil(AirStringCrossing(hysteresis:.nan))
        var d = AirStringCrossing(stringCount:8)!
        _ = d.observe(position:0,time:0)
        let hits = d.observe(position:1,time:0.00001)
        XCTAssertEqual(hits.count,8)
        XCTAssertTrue(hits.allSatisfy { (1...127).contains($0.velocity) })
        XCTAssertTrue(d.observe(position:.infinity,time:0.1).isEmpty)
    }
}
