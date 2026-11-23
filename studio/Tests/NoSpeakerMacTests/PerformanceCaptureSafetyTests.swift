#if os(macOS)
import CoreGraphics
import XCTest
@testable import NoSpeakerMac

final class PerformanceCaptureSafetyTests: XCTestCase {
    func testGlobalEscapeDoesNotPanicWhilePointerIsFree() {
        XCTAssertFalse(PerformanceCaptureSafety.shouldPanicOnGlobalEscape(
            isCaptured: false, keyCode: 53, isRepeat: false
        ))
        XCTAssertFalse(PerformanceCaptureSafety.shouldPanicOnGlobalEscape(
            isCaptured: true, keyCode: 53, isRepeat: true
        ))
        XCTAssertFalse(PerformanceCaptureSafety.shouldPanicOnGlobalEscape(
            isCaptured: true, keyCode: 36, isRepeat: false
        ))
    }

    func testCapturedGlobalEscapeRemainsPanicStop() {
        XCTAssertTrue(PerformanceCaptureSafety.shouldPanicOnGlobalEscape(
            isCaptured: true, keyCode: 53, isRepeat: false
        ))
    }

    func testCapturedShortcutMatchesExactModifiers() {
        guard let event = CGEvent(keyboardEventSource: nil, virtualKey: 46, keyDown: true) else {
            XCTFail("Could not create synthetic local key event")
            return
        }
        event.flags = [.maskControl, .maskAlternate]
        XCTAssertTrue(PerformanceCaptureShortcut.defaultShortcut.matches(event))
        event.flags = [.maskCommand]
        XCTAssertFalse(PerformanceCaptureShortcut.defaultShortcut.matches(event))
    }

    func testEscapeCannotBeRecordedAsCaptureShortcut() {
        XCTAssertFalse(PerformanceCaptureShortcut(
            keyCode: 53, modifiers: 0, displayName: "Esc"
        ).isValid)
        XCTAssertTrue(PerformanceCaptureShortcut(
            keyCode: 49,
            modifiers: CGEventFlags.maskShift.rawValue,
            displayName: "⇧Space"
        ).isValid)
    }
}
#endif
