#if os(macOS)
import XCTest
@testable import NoSpeakerMac

final class PerformanceCaptureDiagnosticsTests: XCTestCase {
    func testFreshMonitorHasNoInputEventsOrActiveTap() {
        let monitor = PerformanceCaptureMonitor()
        let snapshot = monitor.diagnosticSnapshot()
        XCTAssertFalse(snapshot.eventTapCreated)
        XCTAssertFalse(snapshot.eventTapEnabled)
        XCTAssertFalse(snapshot.listening)
        XCTAssertFalse(snapshot.shortcutArmed)
        XCTAssertFalse(snapshot.pointerCaptured)
        XCTAssertEqual(snapshot.keyDownEvents, 0)
        XCTAssertEqual(snapshot.pointerEvents, 0)
        XCTAssertEqual(snapshot.shortcutMatches, 0)
        XCTAssertEqual(snapshot.tapTimeouts, 0)
        XCTAssertEqual(snapshot.coalescedPressureSamples,0)
        XCTAssertEqual(snapshot.physicalMailboxOverflows,0)
        XCTAssertEqual(snapshot.tapDisabledByUserInput, 0)
        XCTAssertEqual(snapshot.lastEventTapStatus, "Not started")
    }

    func testDiagnosticReadDoesNotArmOrCaptureAnything() {
        let monitor = PerformanceCaptureMonitor()
        _ = monitor.diagnosticSnapshot()
        let snapshot = monitor.diagnosticSnapshot()
        XCTAssertFalse(snapshot.shortcutArmed)
        XCTAssertFalse(snapshot.pointerCaptured)
        XCTAssertFalse(snapshot.eventTapCreated)
    }
}
#endif
