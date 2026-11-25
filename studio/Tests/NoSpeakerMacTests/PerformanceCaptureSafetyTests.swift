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

    func testAcceptedPanicSurvivesCaptureReplacementButNotEngineReplacement() {
        // The capture generation can advance while engine generation stays.
        // The emergency policy intentionally has no capture-generation input.
        XCTAssertTrue(PerformanceCaptureSafety.acceptsEmergencyRequest(engineAtCapture:10,currentEngine:10))
        XCTAssertFalse(PerformanceCaptureSafety.acceptsEmergencyRequest(engineAtCapture:10,currentEngine:11))
        XCTAssertFalse(PerformanceCaptureSafety.acceptsEmergencyRequest(engineAtCapture:11,currentEngine:10))
    }

    func testPanicEdgeCanOnlyBeAcceptedOnceWhilePointerIsReleased() {
        var edges = CaptureKeyEdges()
        XCTAssertEqual(edges.handle(key:53,down:true,repeatKey:false,matches:false,armed:true,captured:true),.panic)
        XCTAssertEqual(edges.handle(key:53,down:true,repeatKey:true,matches:false,armed:false,captured:false),.swallow)
        XCTAssertEqual(edges.handle(key:53,down:false,repeatKey:false,matches:false,armed:false,captured:false),.swallow)
        XCTAssertEqual(edges.handle(key:53,down:true,repeatKey:false,matches:false,armed:false,captured:false),.pass)
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
        XCTAssertFalse(monitor.diagnosticSnapshot().shortcutArmed)
        XCTAssertFalse(monitor.diagnosticSnapshot().readyForGlobalCapture)
        XCTAssertFalse(monitor.setPointerCaptured(true))
        XCTAssertFalse(monitor.isCaptured)
        XCTAssertTrue(monitor.setPointerCaptured(false))
    }

    func testCaptureReadinessRequiresLiveDedicatedAuthorizedTap() {
        func snapshot(ax:Bool=true,listenPermission:Bool=true,created:Bool=true,
                      enabled:Bool=true,thread:Bool=true,listening:Bool=true,armed:Bool=true)
            -> PerformanceCaptureDiagnosticSnapshot {
            .init(accessibilityGranted:ax,inputMonitoringGranted:listenPermission,
                  eventTapCreated:created,eventTapEnabled:enabled,dedicatedInputThread:thread,
                  listening:listening,shortcutArmed:armed,pointerCaptured:false,
                  keyDownEvents:0,pointerEvents:0,shortcutMatches:0,tapTimeouts:0,
                  tapDisabledByUserInput:0,lastEventTapStatus:"fixture",
                  coalescedPressureSamples:0,physicalMailboxOverflows:0)
        }
        XCTAssertTrue(snapshot().readyForGlobalCapture)
        XCTAssertTrue(snapshot(listenPermission:false).readyForGlobalCapture)
        XCTAssertTrue(snapshot(armed:false).operational)
        XCTAssertFalse(snapshot(armed:false).readyForGlobalCapture)
        for invalid in [snapshot(ax:false),snapshot(created:false),snapshot(enabled:false),
                        snapshot(thread:false),snapshot(listening:false)] {
            XCTAssertFalse(invalid.operational)
            XCTAssertFalse(invalid.readyForGlobalCapture)
        }
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

    func testInvalidCaptureShortcutNeverStartsOrConsumesModifierEvents() {
        let monitor = PerformanceCaptureMonitor()
        for code in [Int64(53),54,55,56,57,58,59,60,61,62,63,-1,256] {
            let shortcut = PerformanceCaptureShortcut(keyCode:code,modifiers:0,displayName:"Invalid")
            XCTAssertFalse(shortcut.isValid)
            XCTAssertThrowsError(try monitor.start(shortcut:shortcut)) { error in
                guard let failure=error as? PerformanceCaptureError, case .invalidShortcut=failure else {
                    XCTFail("Unexpected error: \(error)"); return
                }
            }
        }
        XCTAssertFalse(monitor.diagnosticSnapshot().eventTapCreated)
        XCTAssertFalse(monitor.isCaptured)
        for code in [Int64(0),36,49,96,105,122,126] {
            XCTAssertTrue(PerformanceCaptureShortcut.acceptsKeyCode(code))
        }
    }

    func testSpecialKeyDisplayFallbackPreservesHardwareCodeAndModifiers() {
        for candidate in [nil,"","  ","\n","\u{0000}",String(repeating:"x",count:129)] as [String?] {
            let name=PerformanceCaptureShortcut.displayLabel(keyCode:105,prefix:"⌃",candidate:candidate)
            XCTAssertEqual(name,"⌃Key 105")
            XCTAssertTrue(PerformanceCaptureShortcut(keyCode:105,
                modifiers:CGEventFlags.maskControl.rawValue,displayName:name).isValid)
        }
        XCTAssertEqual(PerformanceCaptureShortcut.displayLabel(keyCode:36,prefix:"⇧",candidate:"Return"),"⇧Return")
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
        XCTAssertTrue(mailbox.append(.click(true,0.2),now:1))
        for i in 0..<1000 { XCTAssertFalse(mailbox.append(.pressure(Double(i)/1000),now:1+Double(i)/100000)) }
        XCTAssertFalse(mailbox.append(.click(false,0),now:1.02))
        let batch = mailbox.drain(now:1.03)
        XCTAssertEqual(batch.events,[.click(true,0.2),.pressure(0.999),.click(false,0)])
        XCTAssertEqual(mailbox.coalesced,999)
        XCTAssertEqual(batch.receipts,[1,1+999.0/100000,1.02])
        XCTAssertFalse(batch.invalidated)
        XCTAssertTrue(mailbox.append(.click(true,0.3),now:1.04))
    }

    func testCapturePhysicalMailboxOverflowInvalidatesAndDropsUntilDrain() {
        var mailbox = CapturePhysicalMailbox()
        for i in 0...CapturePhysicalMailbox.capacity {
            XCTAssertEqual(mailbox.append(.click(i%2 == 0,0.5),now:2+Double(i)/1000),i == 0)
        }
        XCTAssertFalse(mailbox.append(.click(true,1),now:2.04))
        XCTAssertEqual(mailbox.overflows,1)
        let batch = mailbox.drain(now:2.05)
        XCTAssertTrue(batch.invalidated)
        XCTAssertTrue(batch.events.isEmpty)
        XCTAssertTrue(batch.receipts.isEmpty)
        XCTAssertTrue(mailbox.append(.click(true,0.5),now:2.06))
        XCTAssertFalse(mailbox.drain(now:2.07).invalidated)
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

    func testPhysicalMailboxRejectsClockBeforeLatestEdge() {
        var mailbox = CapturePhysicalMailbox()
        _ = mailbox.append(.click(true,0.5),now:10)
        _ = mailbox.append(.click(false,0),now:10.04)
        let batch = mailbox.drain(now:10.05)
        XCTAssertFalse(mailbox.accepts(batch,now:10.01))
        XCTAssertTrue(mailbox.accepts(batch,now:10.05))
        XCTAssertFalse(mailbox.accepts(batch,now:10.11))
    }

    func testPhysicalMailboxNewDrainRetiresPreviousBatch() {
        var mailbox = CapturePhysicalMailbox()
        _ = mailbox.append(.click(true,0.5),now:11)
        let first = mailbox.drain(now:11.01)
        XCTAssertTrue(mailbox.accepts(first,now:11.02))
        _ = mailbox.append(.click(false,0),now:11.03)
        let second = mailbox.drain(now:11.04)
        XCTAssertFalse(mailbox.accepts(first,now:11.05))
        XCTAssertTrue(mailbox.accepts(second,now:11.05))
        let empty = mailbox.drain(now:11.06)
        XCTAssertFalse(mailbox.accepts(second,now:11.07))
        XCTAssertFalse(mailbox.accepts(empty,now:11.07))
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
        XCTAssertTrue(mailbox.append(.click(true,0.5),now:4))
        XCTAssertFalse(mailbox.invalidate())
        XCTAssertFalse(mailbox.append(.click(false,0),now:4.01))
        let batch = mailbox.drain(now:4.02)
        XCTAssertTrue(batch.invalidated)
        XCTAssertTrue(batch.events.isEmpty)
    }
}
#endif
