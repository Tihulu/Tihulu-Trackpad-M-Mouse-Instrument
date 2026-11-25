#if os(macOS)
import ApplicationServices
import CoreGraphics
import Foundation

/// User-recorded hardware keycode + exact combination of common modifiers.
/// A regular key, function key, or Command/Shift/Option/Control combination
/// can be recorded. Escape is always reserved for Panic Stop.
public struct PerformanceCaptureShortcut: Codable, Hashable, Sendable {
    public var keyCode: Int64
    public var modifiers: UInt64
    public var displayName: String

    public init(keyCode: Int64, modifiers: UInt64, displayName: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers & Self.allowedModifiers
        self.displayName = displayName
    }

    public static var allowedModifiers: UInt64 {
        CGEventFlags.maskShift.rawValue
            | CGEventFlags.maskControl.rawValue
            | CGEventFlags.maskAlternate.rawValue
            | CGEventFlags.maskCommand.rawValue
    }

    public static let defaultShortcut = PerformanceCaptureShortcut(
        keyCode: 46,
        modifiers: CGEventFlags.maskControl.rawValue | CGEventFlags.maskAlternate.rawValue,
        displayName: "⌃⌥M"
    )

    public static func acceptsKeyCode(_ code:Int64)->Bool {
        // Escape is reserved; modifier-only keys produce flagsChanged, not
        // the keyDown/keyUp events observed by this filtering tap.
        (0...255).contains(code) && ![53,54,55,56,57,58,59,60,61,62,63].contains(code)
    }

    /// AppKit can return blank/control-character names for special keys.
    /// Retain the hardware code and use a printable fallback for display.
    public static func displayLabel(keyCode:Int64,prefix:String,candidate:String?)->String {
        let fallback=prefix+"Key "+String(keyCode)
        guard let candidate,
              !candidate.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,
              !candidate.unicodeScalars.contains(where:{ CharacterSet.controlCharacters.contains($0) }),
              (prefix+candidate).utf8.count<=128 else { return fallback }
        return prefix+candidate
    }

    public var isValid: Bool {
        Self.acceptsKeyCode(keyCode) && modifiers & ~Self.allowedModifiers == 0 &&
        !displayName.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty && displayName.utf8.count <= 128 &&
        !displayName.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }

    public func matches(_ event: CGEvent) -> Bool {
        Self.acceptsKeyCode(keyCode) && event.getIntegerValueField(.keyboardEventKeycode) == keyCode &&
        (event.flags.rawValue & Self.allowedModifiers) == modifiers
    }
}

/// A global Escape is an emergency release only while the pointer is captured.
/// Escape remains available to other applications when the capture shortcut is
/// armed but the pointer is free (for example in Logic Pro's dialogs).
public enum PerformanceCaptureSafety {
    public static func shouldPanicOnGlobalEscape(
        isCaptured: Bool, keyCode: Int64, isRepeat: Bool
    ) -> Bool {
        isCaptured && keyCode == 53 && !isRepeat
    }

    /// An accepted emergency edge belongs to the performance engine, not
    /// the replaceable event tap. A new engine must never receive an old panic.
    public static func acceptsEmergencyRequest(engineAtCapture:UInt64,currentEngine:UInt64) -> Bool {
        engineAtCapture == currentEngine
    }
}

/// Pair swallowed downs/ups by hardware keycode, not changing modifiers.
/// A repeat that began in another application is never captured.
struct CaptureKeyEdges {
    enum Action: Equatable { case pass, swallow, toggle, panic }
    private var swallowed: Set<Int64> = []
    mutating func reset() { swallowed.removeAll() }
    mutating func handle(key:Int64,down:Bool,repeatKey:Bool,matches:Bool,armed:Bool,captured:Bool) -> Action {
        if !down { return swallowed.remove(key) != nil ? .swallow : .pass }
        if swallowed.contains(key) { return .swallow }
        if repeatKey { return .pass }
        if PerformanceCaptureSafety.shouldPanicOnGlobalEscape(isCaptured:captured,keyCode:key,isRepeat:repeatKey) {
            swallowed.insert(key); return .panic
        }
        if armed && matches { swallowed.insert(key); return .toggle }
        return .pass
    }
}

/// Pair pointer edges across capture toggles. A click that began outside
/// capture must still deliver its release. A swallowed down must not leak
/// its drag/up to the foreground app when capture ends.
struct CapturePointerEdges {
    enum Edge { case down,up,drag,other }
    private var swallowed:Set<Int64> = []
    private var passed:Set<Int64> = []
    mutating func reset() { swallowed.removeAll(); passed.removeAll() }
    mutating func suppress(button:Int64,edge:Edge,captured:Bool) -> Bool {
        guard (0...31).contains(button) else { return captured }
        switch edge {
        case .down:
            swallowed.remove(button); passed.remove(button)
            if captured { swallowed.insert(button) } else { passed.insert(button) }
            return captured
        case .up:
            if swallowed.remove(button) != nil { return true }
            if passed.remove(button) != nil { return false }
            // Unknown down may have happened before the tap was installed
            // or during a disabled interval. Never trap its release.
            return false
        case .drag: return captured || swallowed.contains(button)
        case .other: return captured
        }
    }
}

/// Permit isolated transient timeout recovery but disarm a repeatedly
/// failing filter. The clock is monotonic; invalid time fails open.
struct CaptureRecoveryBudget {
    static let window:Double = 10
    static let maximum = 3
    private var attempts:[Double] = []
    mutating func allow(now:Double) -> Bool {
        guard now.isFinite,now >= 0,attempts.last.map({ now >= $0 }) ?? true else { return false }
        attempts.removeAll { now-$0 >= Self.window }
        guard attempts.count < Self.maximum else { return false }
        attempts.append(now)
        return true
    }
}

public enum CapturePhysicalInput:Equatable,Sendable {
    case click(Bool,Double)
    case pressure(Double)
}

public struct CapturePhysicalInputBatch:Sendable {
    public let events:[CapturePhysicalInput]
    public let receipts:[Double]
    public let invalidated:Bool
    public let epoch:UInt64
    public let oldestReceipt:Double?
}

/// One notification until drained. Edge order is preserved; consecutive
/// pressure samples replace each other. Overflow drops the entire batch
/// and disarms physical sustain until a fresh click after the drain.
struct CapturePhysicalMailbox {
    static let capacity = 32
    static let maximumAge:Double = 0.1
    private var oldestReceipt:Double?
    private var lastReceipt:Double?
    private(set) var epoch:UInt64 = 0
    private var events:[CapturePhysicalInput] = []
    private var receipts:[Double] = []
    private var invalidated = false
    private var pending = false
    private(set) var coalesced:UInt64 = 0
    private(set) var overflows:UInt64 = 0
    mutating func append(_ event:CapturePhysicalInput,now:Double = ProcessInfo.processInfo.systemUptime) -> Bool {
        guard now.isFinite,now >= 0,lastReceipt.map({ now >= $0 }) ?? true else { return invalidate() }
        lastReceipt = now
        if !invalidated {
            if oldestReceipt == nil { oldestReceipt = now }
            if case .pressure = event, case .pressure? = events.last {
                events[events.count-1] = event
                receipts[receipts.count-1] = now
                if coalesced < UInt64.max { coalesced += 1 }
            } else if events.count < Self.capacity {
                events.append(event)
                receipts.append(now)
            } else {
                events.removeAll(keepingCapacity:true)
                receipts.removeAll(keepingCapacity:true)
                invalidated = true
                epoch &+= 1
                if overflows < UInt64.max { overflows += 1 }
            }
        }
        return notify()
    }
    mutating func invalidate() -> Bool {
        events.removeAll(keepingCapacity:true)
        receipts.removeAll(keepingCapacity:true)
        invalidated = true
        epoch &+= 1
        oldestReceipt = nil
        return notify()
    }
    private mutating func notify() -> Bool {
        guard !pending else { return false }
        pending = true
        return true
    }
    mutating func drain(now:Double = ProcessInfo.processInfo.systemUptime) -> CapturePhysicalInputBatch {
        if !now.isFinite || now < 0 || lastReceipt.map({ now < $0 }) == true ||
            oldestReceipt.map({ now-$0 >= Self.maximumAge }) == true {
            _ = invalidate()
        }
        // Each drain retires the previous delivered batch, even without an
        // overflow or timeout. A delayed consumer cannot replay old edges.
        epoch &+= 1
        let batch = CapturePhysicalInputBatch(events:events,receipts:receipts,invalidated:invalidated,epoch:epoch,oldestReceipt:oldestReceipt)
        events.removeAll(keepingCapacity:true)
        receipts.removeAll(keepingCapacity:true)
        oldestReceipt = nil
        invalidated = false
        pending = false
        return batch
    }
    func accepts(_ batch:CapturePhysicalInputBatch,now:Double) -> Bool {
        guard !invalidated,!batch.invalidated,batch.epoch == epoch,now.isFinite,now >= 0,
              let receipt = batch.oldestReceipt,let latest = batch.receipts.last,
              batch.events.count == batch.receipts.count else { return false }
        // Reject clocks before the most recent edge, not just the first.
        return now >= latest && now >= receipt && now-receipt < Self.maximumAge
    }
}

public enum PerformanceCaptureError: LocalizedError {
    case invalidShortcut
    case permissionDenied
    case tapUnavailable

    public var errorDescription: String? {
        switch self {
        case .invalidShortcut:
            return "Choose a non-modifier key or key combination. Escape is reserved for Panic Stop."
        case .permissionDenied:
            return "Global capture requires Accessibility access for Tihulu Trackpad & M. Mouse Instrument. Enable it in System Settings → Privacy & Security → Accessibility, then restart the app."
        case .tapUnavailable:
            return "Could not start global keyboard/mouse capture. Check System Settings → Privacy & Security → Accessibility and Input Monitoring, restart the app after granting access, then try again. The cursor remains free."
        }
    }
}

/// A privacy-safe, point-in-time diagnostic snapshot. No pressed keys, text,
/// device serial numbers or user paths are recorded; only event counts.
public struct PerformanceCaptureDiagnosticSnapshot: Sendable {
    public let accessibilityGranted: Bool
    public let inputMonitoringGranted: Bool
    public let eventTapCreated: Bool
    public let eventTapEnabled: Bool
    public let dedicatedInputThread: Bool
    public let listening: Bool
    public let shortcutArmed: Bool
    public let pointerCaptured: Bool
    public let keyDownEvents: UInt64
    public let pointerEvents: UInt64
    public let shortcutMatches: UInt64
    public let tapTimeouts: UInt64
    public let tapDisabledByUserInput: UInt64
    public let lastEventTapStatus: String
    public let coalescedPressureSamples:UInt64
    public let physicalMailboxOverflows:UInt64

    /// Input Monitoring preflight is informative: macOS versions can
    /// authorize a filtering tap through Accessibility. Actual tap
    /// operation is required in addition to Accessibility permission.
    public var operational:Bool {
        accessibilityGranted && eventTapCreated && eventTapEnabled && dedicatedInputThread && listening
    }
    public var readyForGlobalCapture:Bool { operational && shortcutArmed }
}

/// Optional event filtering for MIDI performance. Monitoring is OFF by default.
/// If the event tap fails, cursor suppression fails open. All pointer devices
/// are filtered while captured; macOS CGEvent does not reliably identify an
/// individual Magic Mouse versus a trackpad.
public final class PerformanceCaptureMonitor: @unchecked Sendable {
    private let lock = NSLock()
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var inputRunLoop: CFRunLoop?
    private var inputThread: Thread?
    private var inputGeneration: UInt64 = 0
    private var listening = false

    private final class StartGate: @unchecked Sendable {
        let ready = DispatchSemaphore(value: 0)
    }
    private var captured = false
    private var shortcut: PerformanceCaptureShortcut = .defaultShortcut
    private var captureHotkeyEnabled = false
    private var keyEdges = CaptureKeyEdges()
    private var pointerEdges = CapturePointerEdges()
    private var recoveryBudget = CaptureRecoveryBudget()
    private var physicalMailbox = CapturePhysicalMailbox()
    private var startClaimed = false
    private var stopped = false
    private var panicLatched = false
    private var keyDownEvents: UInt64 = 0
    private var pointerEvents: UInt64 = 0
    private var shortcutMatches: UInt64 = 0
    private var tapTimeouts: UInt64 = 0
    private var tapDisabledByUserInput: UInt64 = 0
    private var lastEventTapStatus = "Not started"

    /// Read-only: inspecting system permissions does not request access.
    public func diagnosticSnapshot() -> PerformanceCaptureDiagnosticSnapshot {
        lock.lock()
        let port = eventTap
        let result = (
            listening: listening,
            dedicatedInputThread: inputRunLoop != nil,
            shortcutArmed: captureHotkeyEnabled,
            pointerCaptured: captured,
            keyDownEvents: keyDownEvents,
            pointerEvents: pointerEvents,
            shortcutMatches: shortcutMatches,
            tapTimeouts: tapTimeouts,
            tapDisabledByUserInput: tapDisabledByUserInput,
            lastEventTapStatus: lastEventTapStatus,
            coalescedPressureSamples:physicalMailbox.coalesced,
            physicalMailboxOverflows:physicalMailbox.overflows
        )
        lock.unlock()
        return PerformanceCaptureDiagnosticSnapshot(
            accessibilityGranted: AXIsProcessTrusted(),
            inputMonitoringGranted: CGPreflightListenEventAccess(),
            eventTapCreated: port != nil,
            eventTapEnabled: port.map { CGEvent.tapIsEnabled(tap: $0) } ?? false,
            dedicatedInputThread: result.dedicatedInputThread,
            listening: result.listening,
            shortcutArmed: result.shortcutArmed,
            pointerCaptured: result.pointerCaptured,
            keyDownEvents: result.keyDownEvents,
            pointerEvents: result.pointerEvents,
            shortcutMatches: result.shortcutMatches,
            tapTimeouts: result.tapTimeouts,
            tapDisabledByUserInput: result.tapDisabledByUserInput,
            lastEventTapStatus: result.lastEventTapStatus,
            coalescedPressureSamples:result.coalescedPressureSamples,
            physicalMailboxOverflows:result.physicalMailboxOverflows
        )
    }

    private func markEventTapStatus(_ status: String) {
        lock.lock()
        lastEventTapStatus = status
        lock.unlock()
    }

    public var onCaptureChanged: (@Sendable (Bool) -> Void)?
    public var onPanic: (@Sendable () -> Void)?
    public var onPhysicalClick: (@Sendable (Bool, Double) -> Void)?
    public var onPhysicalPressure: (@Sendable (Double) -> Void)?
    /// Optional bounded delivery path. When installed, supersedes the
    /// individual click/pressure callbacks for this monitor.
    public var onPhysicalInputAvailable:(@Sendable () -> Void)?
    public func drainPhysicalInput() -> CapturePhysicalInputBatch {
        lock.lock(); defer { lock.unlock() }
        return physicalMailbox.drain()
    }
    public func acceptsPhysicalInput(_ batch:CapturePhysicalInputBatch) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return listening && !stopped && !panicLatched && physicalMailbox.accepts(batch,now:ProcessInfo.processInfo.systemUptime)
    }
    public var onMonitorFailed: (@Sendable () -> Void)?
    public var onMonitorRecovered: (@Sendable () -> Void)?

    public init() {}

    deinit { stop() }

    public var isCaptured: Bool {
        lock.lock()
        defer { lock.unlock() }
        return captured
    }

    public func setCaptureHotkeyEnabled(_ enabled: Bool) {
        lock.lock()
        captureHotkeyEnabled = enabled && listening && !stopped && !panicLatched && eventTap != nil
        let armed=captureHotkeyEnabled
        if !armed { captured = false }
        lock.unlock()
        if !armed { onCaptureChanged?(false) }
    }

    public func setShortcut(_ shortcut: PerformanceCaptureShortcut) {
        guard shortcut.isValid else { return }
        lock.lock()
        self.shortcut = shortcut
        lock.unlock()
    }

    public func start(shortcut: PerformanceCaptureShortcut, requestPermissions: Bool = false) throws {
        guard shortcut.isValid else { throw PerformanceCaptureError.invalidShortcut }
        setShortcut(shortcut)
        lock.lock()
        guard !stopped,!panicLatched else { lock.unlock(); throw PerformanceCaptureError.tapUnavailable }
        let existingPort = eventTap
        let existingListening = listening && inputRunLoop != nil
        if existingPort == nil {
            guard !startClaimed else { lock.unlock(); throw PerformanceCaptureError.tapUnavailable }
            startClaimed = true
        }
        lock.unlock()
        if let existingPort {
            if existingListening && AXIsProcessTrusted() && CGEvent.tapIsEnabled(tap: existingPort) { return }
            // Never recycle a disabled instance while old callbacks may be
            // draining. The controller can create a fresh monitor explicitly.
            stop()
            throw PerformanceCaptureError.tapUnavailable
        }

        guard AXIsProcessTrusted() else {
            // The click-sustain monitor can be started while pointer capture is
            // OFF. Only prompt for access when the user explicitly arms capture.
            if requestPermissions {
                let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
                _ = AXIsProcessTrustedWithOptions(options)
            }
            markEventTapStatus("Accessibility permission denied")
            throw PerformanceCaptureError.permissionDenied
        }

        let types: [CGEventType] = [
            .keyDown, .keyUp, .mouseMoved,
            .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp,
            .leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
            .otherMouseDown, .otherMouseUp, .scrollWheel
        ]
        let mask = types.reduce(CGEventMask(0)) {
            $0 | (CGEventMask(1) << CGEventMask($1.rawValue))
        }

        let callback: CGEventTapCallBack = { _, type, event, info in
            guard let info else { return Unmanaged.passUnretained(event) }
            let owner = Unmanaged<PerformanceCaptureMonitor>
                .fromOpaque(info).takeUnretainedValue()
            return owner.handle(type: type, event: event)
        }

        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            // The user explicitly enabled capture. Request Input Monitoring here,
            // never at launch; Accessibility alone may not grant a global event tap.
            if requestPermissions { _ = CGRequestListenEventAccess() }
            markEventTapStatus("Event tap creation failed")
            throw PerformanceCaptureError.tapUnavailable
        }
        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0) else {
            CFMachPortInvalidate(port)
            markEventTapStatus("Event tap run-loop source failed")
            throw PerformanceCaptureError.tapUnavailable
        }

        // A filtering tap must not share SwiftUI's main run loop: when UI,
        // system-audio processing or macOS Continuity work stalls that loop,
        // macOS disables the tap, immediately releasing a captured cursor.
        // The background thread only performs event filtering; AppKit UI
        // callbacks are dispatched asynchronously by the StudioController.
        let gate = StartGate()
        lock.lock()
        guard !stopped else {
            lock.unlock(); CFMachPortInvalidate(port); throw PerformanceCaptureError.tapUnavailable
        }
        inputGeneration &+= 1
        let generation = inputGeneration
        eventTap = port
        runLoopSource = source
        listening = false
        captured = false
        keyEdges.reset()
        pointerEdges.reset()
        recoveryBudget = .init()
        let thread = Thread { [self] in
            runEventTapLoop(generation: generation, gate: gate)
        }
        thread.name = "TIHULU Global Input Capture"
        thread.qualityOfService = .userInteractive
        inputThread = thread
        lock.unlock()
        thread.start()

        // This is a one-time startup handshake, never a per-event wait.
        guard gate.ready.wait(timeout: .now() + .seconds(3)) == .success else {
            markEventTapStatus("Dedicated event tap thread failed to start")
            stop()
            throw PerformanceCaptureError.tapUnavailable
        }
        lock.lock()
        let started = listening && inputGeneration == generation
        lock.unlock()
        guard started && CGEvent.tapIsEnabled(tap: port) else {
            markEventTapStatus("Dedicated event tap was not enabled")
            stop()
            throw PerformanceCaptureError.tapUnavailable
        }
        onCaptureChanged?(false)
    }

    private func runEventTapLoop(generation: UInt64, gate: StartGate) {
        lock.lock()
        let valid = generation == inputGeneration
        let port = valid ? eventTap : nil
        let source = valid ? runLoopSource : nil
        lock.unlock()
        guard let port, let source else {
            gate.ready.signal()
            return
        }

        let loop = CFRunLoopGetCurrent()
        CFRunLoopAddSource(loop, source, CFRunLoopMode.commonModes)
        lock.lock()
        let shouldRun = generation == inputGeneration
        if shouldRun {
            CGEvent.tapEnable(tap: port, enable: true)
            inputRunLoop = loop
            listening = true
            lastEventTapStatus = "Started on dedicated event thread"
        }
        lock.unlock()
        gate.ready.signal()
        if shouldRun {
            // A Stop between the handshake and the first Run must not
            // leave a thread parked forever on a retired source.
            while true {
                lock.lock()
                let current = generation == inputGeneration && listening
                lock.unlock()
                if !current { break }
                let result = CFRunLoopRunInMode(CFRunLoopMode.defaultMode,0.25,false)
                if result == .finished || result == .stopped { break }
            }
        }

        CGEvent.tapEnable(tap: port, enable: false)
        CFRunLoopRemoveSource(loop, source, CFRunLoopMode.commonModes)
        CFMachPortInvalidate(port)
        lock.lock()
        var notifyExit = false
        var notifyPhysical = false
        if generation == inputGeneration {
            let unexpectedExit = listening
            notifyExit = unexpectedExit
            notifyPhysical = physicalMailbox.invalidate()
            inputRunLoop = nil
            inputThread = nil
            eventTap = nil
            runLoopSource = nil
            listening = false
            captured = false
            captureHotkeyEnabled = false
            keyEdges.reset()
            pointerEdges.reset()
            if unexpectedExit { lastEventTapStatus = "Dedicated event loop exited" }
        }
        lock.unlock()
        if notifyPhysical { onPhysicalInputAvailable?() }
        if notifyExit { onCaptureChanged?(false); onMonitorFailed?() }
    }

    public func stop() {
        lock.lock()
        inputGeneration &+= 1
        let port = eventTap
        let loop = inputRunLoop
        stopped = true
        _ = physicalMailbox.invalidate()
        eventTap = nil
        runLoopSource = nil
        inputRunLoop = nil
        inputThread = nil
        listening = false
        captured = false
        captureHotkeyEnabled = false
        keyEdges.reset()
        pointerEdges.reset()
        // Retain the last failure reason for diagnosis; do not erase it.
        lock.unlock()

        if let port { CGEvent.tapEnable(tap: port, enable: false) }
        if let loop {
            CFRunLoopStop(loop)
            CFRunLoopWakeUp(loop)
        } else if let port {
            CFMachPortInvalidate(port)
        }
        onCaptureChanged?(false)
    }

    /// Explicit capture does not require a functioning shortcut but does
    /// require the same active, authorized filtering tap and armed state.
    @discardableResult
    public func setPointerCaptured(_ value:Bool) -> Bool {
        if !value { releasePointer(); return true }
        // Permission IPC must not run while holding the native input lock.
        let authorized = AXIsProcessTrusted()
        lock.lock()
        guard authorized,listening,!stopped,!panicLatched,captureHotkeyEnabled,let port = eventTap,
              CGEvent.tapIsEnabled(tap:port) else {
            captured = false
            lock.unlock()
            onCaptureChanged?(false)
            return false
        }
        captured = true
        lock.unlock()
        onCaptureChanged?(true)
        return true
    }

    /// Atomically choose release versus capture from the actual tap state.
    /// Releasing remains available even when permission has been revoked.
    public func togglePointerCapture() -> Bool {
        let authorized=AXIsProcessTrusted()
        lock.lock()
        if captured {
            captured=false
            lock.unlock()
            onCaptureChanged?(false)
            return false
        }
        guard authorized,listening,!stopped,!panicLatched,captureHotkeyEnabled,
              let port=eventTap,CGEvent.tapIsEnabled(tap:port) else {
            lock.unlock()
            onCaptureChanged?(false)
            return false
        }
        captured=true
        lock.unlock()
        onCaptureChanged?(true)
        return true
    }

    public func releasePointer() {
        lock.lock()
        captured = false
        lock.unlock()
        onCaptureChanged?(false)
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        let passthrough = Unmanaged.passUnretained(event)

        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            lock.lock()
            guard listening,let port = eventTap else { lock.unlock(); return passthrough }
            captured = false
            // An up may be missing. Forget edge ownership and permit unknown
            // pointer releases so recovery cannot trap a foreground drag.
            keyEdges.reset()
            pointerEdges.reset()
            let signal = physicalMailbox.invalidate()
            var recovered = false
            if type == .tapDisabledByTimeout {
                tapTimeouts &+= 1
                lastEventTapStatus = "Disabled by macOS timeout"
                if recoveryBudget.allow(now:ProcessInfo.processInfo.systemUptime) {
                    // Serialize enable with Stop's state transition; do not
                    // enable a port that Stop has already retired.
                    CGEvent.tapEnable(tap:port,enable:true)
                    recovered = CGEvent.tapIsEnabled(tap:port)
                    if recovered { lastEventTapStatus = "Recovered after timeout" }
                } else { lastEventTapStatus = "Repeated timeouts; explicit re-enable required" }
            } else {
                tapDisabledByUserInput &+= 1
                lastEventTapStatus = "Disabled by macOS/user input"
            }
            if !recovered {
                listening = false
                captureHotkeyEnabled = false
            }
            lock.unlock()
            onCaptureChanged?(false)
            if signal { onPhysicalInputAvailable?() }
            if recovered { onMonitorRecovered?() }
            else { onMonitorFailed?() }
            return passthrough
        }

        if type == .keyDown || type == .keyUp {
            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
            let repeatKey = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
            if type == .keyDown && !repeatKey {
                lock.lock()
                keyDownEvents &+= 1
                lock.unlock()
            }

            lock.lock()
            guard listening else { lock.unlock(); return passthrough }
            let action = keyEdges.handle(key:keyCode,down:type == .keyDown,repeatKey:repeatKey,
                                         matches:shortcut.matches(event),armed:listening && captureHotkeyEnabled,
                                         captured:captured)
            var changed: Bool?
            var invalidateSignal = false
            if action == .toggle {
                shortcutMatches &+= 1
                captured.toggle()
                changed = captured
            } else if action == .panic {
                captured = false
                captureHotkeyEnabled = false
                panicLatched = true
                invalidateSignal = physicalMailbox.invalidate()
                changed = false
            }
            lock.unlock()
            // Deliver the emergency intent before ordinary physical/UI
            // notifications. It has already synchronously freed the pointer.
            if action == .panic { onPanic?() }
            if invalidateSignal { onPhysicalInputAvailable?() }
            if let changed { onCaptureChanged?(changed) }
            if action != .pass { return nil }
            return passthrough
        }

        lock.lock()
        guard listening else { lock.unlock(); return passthrough }
        pointerEvents &+= 1
        let edge:CapturePointerEdges.Edge
        let button:Int64
        switch type {
        case .leftMouseDown,.leftMouseUp,.leftMouseDragged: button = 0
        case .rightMouseDown,.rightMouseUp,.rightMouseDragged: button = 1
        default: button = event.getIntegerValueField(.mouseEventButtonNumber)
        }
        switch type {
        case .leftMouseDown,.rightMouseDown,.otherMouseDown: edge = .down
        case .leftMouseUp,.rightMouseUp,.otherMouseUp: edge = .up
        case .leftMouseDragged,.rightMouseDragged,.otherMouseDragged: edge = .drag
        default: edge = .other
        }
        let suppress = pointerEdges.suppress(button:button,edge:edge,captured:captured)
        let bounded = onPhysicalInputAvailable
        var signal = false
        let physicalAllowed = !panicLatched
        if physicalAllowed && bounded != nil {
            if type == .leftMouseDown || type == .leftMouseUp {
                signal = physicalMailbox.append(.click(type == .leftMouseDown,event.getDoubleValueField(.mouseEventPressure)))
            } else if type == .leftMouseDragged {
                signal = physicalMailbox.append(.pressure(event.getDoubleValueField(.mouseEventPressure)))
            }
        }
        lock.unlock()
        if signal { bounded?() }

        if physicalAllowed && bounded == nil && (type == .leftMouseDown || type == .leftMouseUp) {
            onPhysicalClick?(
                type == .leftMouseDown,
                event.getDoubleValueField(.mouseEventPressure)
            )
        } else if physicalAllowed && bounded == nil && type == .leftMouseDragged {
            onPhysicalPressure?(event.getDoubleValueField(.mouseEventPressure))
        }

        // Capture cannot distinguish mouse and trackpad at CGEvent level;
        // suppress all OS pointer movement/clicks while the mode is enabled.
        // Escape and the assigned keyboard shortcut always remain available.
        if suppress { return nil }
        return passthrough
    }
}
#endif
