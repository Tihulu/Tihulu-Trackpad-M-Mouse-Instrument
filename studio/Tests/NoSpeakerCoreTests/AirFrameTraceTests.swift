import XCTest
@testable import NoSpeakerCore

final class AirFrameTraceTests: XCTestCase {
    func testTracePreservesOffsetsAndLoss() {
        var trace = AirFrameTrace()
        let hand = AirHandSample.debugSample(x: 0.2,y: 0.7,aperture: 0.8)
        XCTAssertTrue(trace.append(count: 0,confidence: 1,helper: hand,time: 10))
        XCTAssertTrue(trace.append(count: 3,confidence: 1,helper: hand,time: 10.1))
        XCTAssertTrue(trace.append(count: 3,confidence: .nan,helper: hand,time: 10.2))
        XCTAssertEqual(trace.frames.count,3)
        XCTAssertEqual(trace.frames[1].offset,0.1,accuracy: 1e-9)
        XCTAssertNil(trace.frames[2].count)
        XCTAssertNil(trace.frames[2].helper)
        XCTAssertFalse(trace.append(count: 3,confidence: 1,helper: hand,time: 10.1))
        XCTAssertFalse(trace.append(count: 3,confidence: 1,helper: hand,time: 41))
        XCTAssertEqual(trace.frames.count,3)
    }

    func testTraceBoundedAndReplayMatchesRecordedFrames() throws {
        var trace = AirFrameTrace()
        let open = AirHandSample.debugSample(x: 0.2,y: 0.7,aperture: 0.8)
        let closed = AirHandSample.debugSample(x: 0.2,y: 0.7,aperture: 0.1)
        let patch = InstrumentPatch(name:"Trace",routes:AirDualHandPerformance.routes())
        var live = PhysicalPatchRuntime()
        var debug = PatchSimulation()
        try live.configure(patch)
        try debug.start(patch,now:0)
        let input: [(Int?,AirHandSample?,Double)] = [(0,open,10),(1,open,10.01),(1,open,10.15),(1,closed,10.16),(nil,nil,10.2)]
        var expected: [[SensorCommand]] = []
        for (count,hand,time) in input {
            XCTAssertTrue(trace.append(count:count,confidence:1,helper:hand,time:time))
            expected.append(live.receiveDualHand(count:count,confidence:1,helper:hand,hostTime:time,now:time))
        }
        for (i,frame) in trace.frames.enumerated() {
            XCTAssertEqual(debug.receiveDualHand(count:frame.count,confidence:frame.confidence,helper:frame.helper,time:frame.offset,now:frame.offset),expected[i])
        }
        XCTAssertEqual(expected[3].filter { $0.value > 0 }.count,3)
        XCTAssertEqual(expected[4].filter { $0.value == 0 }.count,3)
        var bounded = AirFrameTrace()
        for i in 0..<AirFrameTrace.maximumFrames {
            XCTAssertTrue(bounded.append(count:nil,confidence:0,helper:nil,time:Double(i)/30))
        }
        XCTAssertFalse(bounded.append(count:nil,confidence:0,helper:nil,time:25))
    }

    func testSingleHandCannotBypassDualMode() throws {
        var live = PhysicalPatchRuntime()
        let contact = SensorMapping(id:"contact",source:.camera,signal:.contact,destination:.init(.note,number:80))
        try live.configure(.init(name:"Dual",routes:AirDualHandPerformance.routes()+[contact]))
        XCTAssertTrue(live.receiveHand(AirHandSample.debugSample(x:0.5,y:0.5,aperture:0.5),hostTime:0,now:0).isEmpty)
        XCTAssertFalse(live.activeSources.contains(.camera))
    }
}
