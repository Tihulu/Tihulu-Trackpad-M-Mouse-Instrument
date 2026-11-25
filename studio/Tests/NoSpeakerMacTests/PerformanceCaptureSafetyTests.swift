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

    func testPointerReleasePairingAcrossCaptureChanges() {
        var edges = CapturePointerEdges()
        XCTAssertFalse(edges.suppress(button:0,edge:.down,captured:false))
        XCTAssertTrue(edges.suppress(button:0,edge:.drag,captured:true))
        XCTAssertFalse(edges.suppress(button:0,edge:.up,captured:true))
        XCTAssertTrue(edges.suppress(button:1,edge:.down,captured:true))
        XCTAssertTrue(edges.suppress(button:1,edge:.drag,captured:false))
        XCTAssertTrue(edges.suppress(button:1,edge:.up,captured:false))
        XCTAssertFalse(edges.suppress(button:1,edge:.down,captured:false))
        XCTAssertFalse(edges.suppress(button:1,edge:.up,captured:false))
    }

    func testUnknownPointerReleaseAfterTimeoutIsNotTrapped() {
        var edges = CapturePointerEdges()
        XCTAssertTrue(edges.suppress(button:0,edge:.down,captured:true))
        edges.reset()
        XCTAssertFalse(edges.suppress(button:0,edge:.up,captured:true))
        XCTAssertTrue(edges.suppress(button:0,edge:.other,captured:true))
    }

    func testLostKeyUpDoesNotBlockNextFreshShortcutAfterReset() {
        var edges = CaptureKeyEdges()
        XCTAssertEqual(edges.handle(key:46,down:true,repeatKey:false,matches:true,armed:true,captured:false),.toggle)
        edges.reset()
        XCTAssertEqual(edges.handle(key:46,down:true,repeatKey:true,matches:true,armed:true,captured:false),.pass)
        XCTAssertEqual(edges.handle(key:46,down:true,repeatKey:false,matches:true,armed:true,captured:false),.toggle)
    }

    func testCaptureRecoveryBudgetBoundsRepeatedTimeouts() {
        var budget = CaptureRecoveryBudget()
        XCTAssertTrue(budget.allow(now:1))
        XCTAssertTrue(budget.allow(now:2))
        XCTAssertTrue(budget.allow(now:3))
        XCTAssertFalse(budget.allow(now:4))
        XCTAssertFalse(budget.allow(now:2))
        XCTAssertFalse(budget.allow(now:.nan))
        XCTAssertTrue(budget.allow(now:11))
    }

    func testCapturePhysicalMailboxCoalescesPressureAndPreservesClickOrder() {
        var mailbox = CapturePhysicalMailbox()
        XCTAssertTrue(mailbox.append(.click(true,0.2)))
        for i in 0..<1000 { XCTAssertFalse(mailbox.append(.pressure(Double(i)/1000))) }
        XCTAssertFalse(mailbox.append(.click(false,0)))
        let batch = mailbox.drain()
        XCTAssertEqual(batch.events,[.click(true,0.2),.pressure(0.999),.click(false,0)])
        XCTAssertEqual(mailbox.coalesced,999)
        XCTAssertFalse(batch.invalidated)
        XCTAssertTrue(mailbox.append(.click(true,0.3)))
    }

    func testCapturePhysicalMailboxOverflowInvalidatesAndDropsUntilDrain() {
        var mailbox = CapturePhysicalMailbox()
        for i in 0...CapturePhysicalMailbox.capacity {
            XCTAssertEqual(mailbox.append(.click(i%2 == 0,0.5)),i == 0)
        }
        XCTAssertFalse(mailbox.append(.click(true,1)))
        XCTAssertEqual(mailbox.overflows,1)
        let batch = mailbox.drain()
        XCTAssertTrue(batch.invalidated)
        XCTAssertTrue(batch.events.isEmpty)
        XCTAssertTrue(mailbox.append(.click(true,0.5)))
        XCTAssertFalse(mailbox.drain().invalidated)
    }

    func testStoppedCaptureMonitorCannotRestartOrCapture() {
        let monitor = PerformanceCaptureMonitor()
        monitor.stop()
        XCTAssertThrowsError(try monitor.start(shortcut:.defaultShortcut))
        XCTAssertFalse(monitor.setPointerCaptured(true))
        XCTAssertFalse(monitor.diagnosticSnapshot().eventTapCreated)
    }

    func testPhysicalMailboxOldClickCannotBeRefreshedByNewPressure() {
        var mailbox = CapturePhysicalMailbox()
        XCTAssertTrue(mailbox.append(.click(true,0.5),now:1))
        XCTAssertFalse(mailbox.append(.pressure(0.7),now:1.09))
        let batch = mailbox.drain(now:1.101)
        XCTAssertTrue(batch.invalidated)
        XCTAssertTrue(batch.events.isEmpty)
        XCTAssertTrue(mailbox.append(.click(false,0),now:1.11))
        XCTAssertFalse(mailbox.drain(now:1.12).invalidated)
    }

    func testPhysicalMailboxDrainedBatchCannotSurviveInvalidationOrExpiry() {
        var mailbox = CapturePhysicalMailbox()
        _ = mailbox.append(.click(true,0.5),now:2)
        let batch = mailbox.drain(now:2.01)
        XCTAssertTrue(mailbox.accepts(batch,now:2.02))
        XCTAssertFalse(mailbox.accepts(batch,now:2.11))
        _ = mailbox.invalidate()
        _ = mailbox.drain(now:2.03)
        XCTAssertFalse(mailbox.accepts(batch,now:2.04))
    }

    func testPhysicalMailboxInvalidAndReversedReceiptFailOpen() {
        var mailbox = CapturePhysicalMailbox()
        _ = mailbox.append(.click(true,0.5),now:3)
        _ = mailbox.append(.click(false,0),now:2.99)
        XCTAssertTrue(mailbox.drain(now:3.01).invalidated)
        _ = mailbox.append(.click(true,0.5),now:3.02)
        XCTAssertTrue(mailbox.drain(now:.nan).invalidated)
    }

    func testCapturePhysicalMailboxTimeoutDiscardsAlreadyQueuedEdges() {
        var mailbox = CapturePhysicalMailbox()
        XCTAssertTrue(mailbox.append(.click(true,0.5)))
        XCTAssertFalse(mailbox.invalidate())
        XCTAssertFalse(mailbox.append(.click(false,0)))
        let batch = mailbox.drain()
        XCTAssertTrue(batch.invalidated)
        XCTAssertTrue(batch.events.isEmpty)
    }
}
#endif
