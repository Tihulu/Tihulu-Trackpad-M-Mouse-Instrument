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

    public var isValid: Bool { keyCode != 53 && keyCode >= 0 && !displayName.isEmpty }

    public func matches(_ event: CGEvent) -> Bool {
        event.getIntegerValueField(.keyboardEventKeycode) == keyCode &&
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
}

public enum PerformanceCaptureError: LocalizedError {
    case permissionDenied
    case tapUnavailable

    public var errorDescription: String? {
        switch self {
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
            lastEventTapStatus: lastEventTapStatus
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
            lastEventTapStatus: result.lastEventTapStatus
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
        captureHotkeyEnabled = enabled
        if !enabled { captured = false }
        lock.unlock()
        if !enabled { onCaptureChanged?(false) }
    }

    public func setShortcut(_ shortcut: PerformanceCaptureShortcut) {
        guard shortcut.isValid else { return }
        lock.lock()
        self.shortcut = shortcut
        lock.unlock()
    }

    public func start(shortcut: PerformanceCaptureShortcut, requestPermissions: Bool = false) throws {
        setShortcut(shortcut)
        lock.lock()
        let existingPort = listening ? eventTap : nil
        lock.unlock()
        if let existingPort {
            if CGEvent.tapIsEnabled(tap: existingPort) { return }
            stop()
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
        inputGeneration &+= 1
        let generation = inputGeneration
        eventTap = port
        runLoopSource = source
        listening = false
        captured = false
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
        CGEvent.tapEnable(tap: port, enable: true)
        lock.lock()
        let shouldRun = generation == inputGeneration
        if shouldRun {
            inputRunLoop = loop
            listening = true
            lastEventTapStatus = "Started on dedicated event thread"
        }
        lock.unlock()
        gate.ready.signal()
        if shouldRun { CFRunLoopRun() }

        CGEvent.tapEnable(tap: port, enable: false)
        CFRunLoopRemoveSource(loop, source, CFRunLoopMode.commonModes)
        CFMachPortInvalidate(port)
        lock.lock()
        if generation == inputGeneration {
            inputRunLoop = nil
            inputThread = nil
            eventTap = nil
            runLoopSource = nil
            listening = false
            captured = false
        }
        lock.unlock()
    }

    public func stop() {
        lock.lock()
        inputGeneration &+= 1
        let port = eventTap
        let loop = inputRunLoop
        let pendingThread = inputThread != nil
        eventTap = nil
        runLoopSource = nil
        inputRunLoop = nil
        inputThread = nil
        listening = false
        captured = false
        captureHotkeyEnabled = false
        // Retain the last failure reason for diagnosis; do not erase it.
        lock.unlock()

        if let port { CGEvent.tapEnable(tap: port, enable: false) }
        if let loop {
            CFRunLoopStop(loop)
            CFRunLoopWakeUp(loop)
        } else if !pendingThread, let port {
            CFMachPortInvalidate(port)
        }
        onCaptureChanged?(false)
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
            if type == .tapDisabledByTimeout {
                tapTimeouts &+= 1
                lastEventTapStatus = "Disabled by macOS timeout"
            } else {
                tapDisabledByUserInput &+= 1
                lastEventTapStatus = "Disabled by macOS/user input"
            }
            lock.unlock()
            // Fail open immediately: never leave the pointer captured after the
            // system disables this event tap. A timeout can be transient when the
            // macOS or other system services temporarily delay event delivery.
            releasePointer()
            if type == .tapDisabledByTimeout {
                lock.lock()
                let port = eventTap
                let wasListening = listening
                lock.unlock()
                if wasListening, let port {
                    CGEvent.tapEnable(tap: port, enable: true)
                    if CGEvent.tapIsEnabled(tap: port) {
                        markEventTapStatus("Recovered after timeout")
                        onMonitorRecovered?()
                        return passthrough
                    }
                }
            }
            // A user/system-disabled tap must not be overridden automatically.
            // The controller disarms monitoring without closing the haptic driver.
            onMonitorFailed?()
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

            // Esc is a global emergency kill switch ONLY while this monitor
            // is running. Never require the user to recover the mouse first.
            if type == .keyDown,
               PerformanceCaptureSafety.shouldPanicOnGlobalEscape(
                   isCaptured: isCaptured,
                   keyCode: keyCode,
                   isRepeat: repeatKey
               ) {
                releasePointer()
                onPanic?()
                return nil
            }

            lock.lock()
            let currentShortcut = shortcut
            let hotkeyEnabled = captureHotkeyEnabled
            lock.unlock()
            let matches = currentShortcut.matches(event)
            if matches && hotkeyEnabled {
                if type == .keyDown, !repeatKey {
                    lock.lock()
                    guard listening && captureHotkeyEnabled && shortcut.matches(event) else {
                        lock.unlock()
                        return passthrough
                    }
                    shortcutMatches &+= 1
                    captured.toggle()
                    let newCaptureState = captured
                    lock.unlock()
                    onCaptureChanged?(newCaptureState)
                }
                return nil
            }
            return passthrough
        }

        if type == .leftMouseDown || type == .leftMouseUp {
            onPhysicalClick?(
                type == .leftMouseDown,
                event.getDoubleValueField(.mouseEventPressure)
            )
        } else if type == .leftMouseDragged {
            onPhysicalPressure?(event.getDoubleValueField(.mouseEventPressure))
        }

        lock.lock()
        pointerEvents &+= 1
        let suppress = captured
        lock.unlock()
        // Capture cannot distinguish mouse and trackpad at CGEvent level;
        // suppress all OS pointer movement/clicks while the mode is enabled.
        // Escape and the assigned keyboard shortcut always remain available.
        if suppress { return nil }
        return passthrough
    }
}
#endif
