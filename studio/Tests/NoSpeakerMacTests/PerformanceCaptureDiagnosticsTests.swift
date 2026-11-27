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

    func testStaleCaptureLatchDoesNotReportActivePointerSuppression() {
        for mask in 0..<128 {
            let authorized = mask & 1 != 0
            let preflight = mask & 2 != 0
            let created = mask & 4 != 0
            let enabled = mask & 8 != 0
            let dedicated = mask & 16 != 0
            let listening = mask & 32 != 0
            let armed = mask & 64 != 0
            let snapshot = PerformanceCaptureDiagnosticSnapshot(
                accessibilityGranted: authorized, inputMonitoringGranted: preflight,
                eventTapCreated: created, eventTapEnabled: enabled,
                dedicatedInputThread: dedicated, listening: listening, shortcutArmed: armed,
                captureLatched: true, keyDownEvents: 8, pointerEvents: 20, shortcutMatches: 2,
                tapTimeouts: 1, tapDisabledByUserInput: 0, lastEventTapStatus: "fixture",
                coalescedPressureSamples: 0, physicalMailboxOverflows: 0
            )
            // The preflight hint (bit 1) is optional when the tap is live.
            XCTAssertEqual(snapshot.pointerCaptured, (mask | 2) == 127, "mask \(mask)")
            XCTAssertEqual(snapshot.shortcutMatches, 2)
            XCTAssertEqual(snapshot.tapTimeouts, 1)
        }
    }
}
#endif
