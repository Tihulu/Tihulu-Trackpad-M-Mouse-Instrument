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

public enum PerformanceCaptureError: LocalizedError {
    case permissionDenied
    case tapUnavailable

    public var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return "Performance capture requires Accessibility permission for NoSpeaker Studio. Enable it under System Settings → Privacy & Security → Accessibility, then restart Studio."
        case .tapUnavailable:
            return "Could not create a safe keyboard/mouse event monitor. Mouse cursor remains available to macOS; no pointer events have been captured."
        }
    }
}

/// Optional event filtering for MIDI performance. Monitoring is OFF by default.
/// If the event tap fails, cursor suppression fails open. All pointer devices
/// are filtered while captured; macOS CGEvent does not reliably identify an
/// individual Magic Mouse versus a trackpad.
public final class PerformanceCaptureMonitor: @unchecked Sendable {
    private let lock = NSLock()
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var listening = false
    private var captured = false
    private var shortcut: PerformanceCaptureShortcut = .defaultShortcut
    private var captureHotkeyEnabled = false

    public var onCaptureChanged: (@Sendable (Bool) -> Void)?
    public var onPanic: (@Sendable () -> Void)?
    public var onPhysicalClick: (@Sendable (Bool, Double) -> Void)?
    public var onPhysicalPressure: (@Sendable (Double) -> Void)?
    public var onMonitorFailed: (@Sendable () -> Void)?

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

    public func start(shortcut: PerformanceCaptureShortcut) throws {
        setShortcut(shortcut)
        lock.lock()
        let alreadyListening = listening
        lock.unlock()
        if alreadyListening { return }

        guard AXIsProcessTrusted() else {
            // Only request this system prompt after the user explicitly
            // enables the performance monitor, never on app launch.
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
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
            throw PerformanceCaptureError.tapUnavailable
        }
        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0) else {
            CFMachPortInvalidate(port)
            throw PerformanceCaptureError.tapUnavailable
        }

        CFRunLoopAddSource(CFRunLoopGetMain(), source, CFRunLoopMode.commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        lock.lock()
        eventTap = port
        runLoopSource = source
        listening = true
        captured = false
        lock.unlock()
        onCaptureChanged?(false)
    }

    public func stop() {
        lock.lock()
        let port = eventTap
        let source = runLoopSource
        eventTap = nil
        runLoopSource = nil
        listening = false
        captured = false
        lock.unlock()

        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, CFRunLoopMode.commonModes) }
        if let port { CGEvent.tapEnable(tap: port, enable: false); CFMachPortInvalidate(port) }
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
            releasePointer()
            onMonitorFailed?()
            return passthrough
        }

        if type == .keyDown || type == .keyUp {
            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
            let repeatKey = event.getIntegerValueField(.keyboardEventAutorepeat) != 0

            // Esc is a global emergency kill switch ONLY while this monitor
            // is running. Never require the user to recover the mouse first.
            if keyCode == 53, type == .keyDown, !repeatKey {
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
