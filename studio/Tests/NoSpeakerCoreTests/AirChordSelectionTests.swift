import XCTest
@testable import NoSpeakerCore

final class AirChordSelectionTests: XCTestCase {
    private let bank = [[60,64,67],[62,65,69],[64,67,71],[65,69,72],[67,71,74]]
    private func model() -> AirChordSelection {
        AirChordSelection(slots: bank, debounce: 0.1, maximumGap: 0.25)!
    }

    func testInvalidBankAndTiming() {
        XCTAssertNil(AirChordSelection(slots: []))
        XCTAssertNil(AirChordSelection(slots: Array(repeating: [128], count: 5)))
        XCTAssertNil(AirChordSelection(slots: Array(repeating: [60,60], count: 5)))
        XCTAssertNil(AirChordSelection(slots: bank, debounce: .nan))
        XCTAssertNil(AirChordSelection(slots: bank, maximumGap: 0))
        XCTAssertNil(AirChordSelection(slots: bank, minimumConfidence: .infinity))
    }

    func testAllFiveSlotsAndNoRepeat() {
        for count in 1...5 {
            var s = model()
            XCTAssertEqual(s.observe(count: 0, confidence: 1, time: 0), .unchanged)
            XCTAssertEqual(s.observe(count: count, confidence: 1, time: 0.01), .unchanged)
            XCTAssertEqual(s.observe(count: count, confidence: 1, time: 0.15),
                           .selected(slot: count, notes: bank[count - 1]))
            XCTAssertEqual(s.observe(count: count, confidence: 1, time: 0.2), .unchanged)
            XCTAssertEqual(s.observe(count: 0, confidence: 1, time: 0.21), .releaseOwned)
            XCTAssertNil(s.selectedSlot)
        }
    }

    func testJitterDoesNotCommit() {
        var s = model()
        _ = s.observe(count: 0, confidence: 1, time: 0)
        _ = s.observe(count: 1, confidence: 1, time: 0.01)
        _ = s.observe(count: 2, confidence: 1, time: 0.09)
        XCTAssertEqual(s.observe(count: 1, confidence: 1, time: 0.15), .unchanged)
        XCTAssertNil(s.selectedSlot)
        XCTAssertEqual(s.observe(count: 1, confidence: 1, time: 0.27),
                       .selected(slot: 1, notes: bank[0]))
    }

    func testLossRequiresNeutral() {
        var s = model()
        _ = s.observe(count: 0, confidence: 1, time: 0)
        _ = s.observe(count: 1, confidence: 1, time: 0.01)
        _ = s.observe(count: 1, confidence: 1, time: 0.15)
        XCTAssertEqual(s.observe(count: nil, confidence: 0, time: 0.2), .releaseOwned)
        XCTAssertEqual(s.observe(count: 2, confidence: 1, time: 0.3), .unchanged)
        XCTAssertEqual(s.observe(count: 2, confidence: 1, time: 0.45), .unchanged)
        _ = s.observe(count: 0, confidence: 1, time: 0.5)
        _ = s.observe(count: 2, confidence: 1, time: 0.51)
        XCTAssertEqual(s.observe(count: 2, confidence: 1, time: 0.65),
                       .selected(slot: 2, notes: bank[1]))
    }

    func testInvalidAndReorderedFramesFailClosed() {
        var s = model()
        _ = s.observe(count: 0, confidence: 1, time: 1)
        XCTAssertEqual(s.observe(count: 1, confidence: .nan, time: 1.1), .releaseOwned)
        XCTAssertEqual(s.observe(count: 0, confidence: 1, time: 1), .releaseOwned)
        XCTAssertEqual(s.observe(count: 6, confidence: 1, time: 1.2), .releaseOwned)
        XCTAssertEqual(s.observe(count: 0, confidence: 1, time: .infinity), .releaseOwned)
        XCTAssertEqual(s.observe(count: 0, confidence: 1, time: 1.3), .unchanged)
    }

    func testWatchdogAndGap() {
        var s = model()
        _ = s.observe(count: 0, confidence: 1, time: 0)
        _ = s.observe(count: 3, confidence: 1, time: 0.01)
        _ = s.observe(count: 3, confidence: 1, time: 0.15)
        XCTAssertEqual(s.expire(at: 0.2), .unchanged)
        XCTAssertEqual(s.expire(at: 0.5), .releaseOwned)
        XCTAssertNil(s.selectedSlot)
        XCTAssertEqual(s.observe(count: 3, confidence: 1, time: 0.51), .releaseOwned)
        XCTAssertEqual(s.observe(count: 3, confidence: 1, time: 0.6), .unchanged)
    }
}
