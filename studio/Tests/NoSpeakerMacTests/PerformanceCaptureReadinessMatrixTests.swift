#if os(macOS)
import Testing
@testable import NoSpeakerMac

@Test func captureDiagnosticReadinessDoesNotImplyPointerCapture() {
    for mask in 0..<256 {
        let snapshot = PerformanceCaptureDiagnosticSnapshot(
            accessibilityGranted: mask & 1 != 0,
            inputMonitoringGranted: mask & 2 != 0,
            eventTapCreated: mask & 4 != 0,
            eventTapEnabled: mask & 8 != 0,
            dedicatedInputThread: mask & 16 != 0,
            listening: mask & 32 != 0,
            shortcutArmed: mask & 64 != 0,
            captureLatched: mask & 128 != 0,
            keyDownEvents: 3, pointerEvents: 5, shortcutMatches: 7,
            tapTimeouts: 11, tapDisabledByUserInput: 13,
            lastEventTapStatus: "matrix", coalescedPressureSamples: 17,
            physicalMailboxOverflows: 19
        )
        // Input Monitoring preflight is a hint, not a live-tap gate.
        #expect(snapshot.operational == (mask & 61 == 61))
        #expect(snapshot.readyForGlobalCapture == (mask & 125 == 125))
        #expect(snapshot.pointerCaptured == (mask & 253 == 253))
    }
}
#endif
