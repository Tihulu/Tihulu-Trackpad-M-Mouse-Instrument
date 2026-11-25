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

    func testCapturedShortcutPairsUpDespiteChangedModifiers() {
        var edges = CaptureKeyEdges()
        XCTAssertEqual(edges.handle(key:46,down:true,repeatKey:false,matches:true,armed:true,captured:false),.toggle)
        XCTAssertEqual(edges.handle(key:46,down:true,repeatKey:true,matches:false,armed:true,captured:true),.swallow)
        XCTAssertEqual(edges.handle(key:46,down:false,repeatKey:false,matches:false,armed:false,captured:false),.swallow)
        XCTAssertEqual(edges.handle(key:46,down:false,repeatKey:false,matches:true,armed:true,captured:false),.pass)
    }

    func testExternalRepeatAndEscapePairing() {
        var edges = CaptureKeyEdges()
        XCTAssertEqual(edges.handle(key:46,down:true,repeatKey:true,matches:true,armed:true,captured:false),.pass)
        XCTAssertEqual(edges.handle(key:53,down:true,repeatKey:false,matches:false,armed:true,captured:true),.panic)
        XCTAssertEqual(edges.handle(key:53,down:true,repeatKey:true,matches:false,armed:true,captured:false),.swallow)
        XCTAssertEqual(edges.handle(key:53,down:false,repeatKey:false,matches:false,armed:true,captured:false),.swallow)
        XCTAssertEqual(edges.handle(key:53,down:true,repeatKey:false,matches:false,armed:true,captured:false),.pass)
    }

    func testDirectCaptureRequiresActiveTap() {
        let monitor = PerformanceCaptureMonitor()
        monitor.setCaptureHotkeyEnabled(true)
        XCTAssertFalse(monitor.setPointerCaptured(true))
        XCTAssertFalse(monitor.isCaptured)
        XCTAssertTrue(monitor.setPointerCaptured(false))
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
