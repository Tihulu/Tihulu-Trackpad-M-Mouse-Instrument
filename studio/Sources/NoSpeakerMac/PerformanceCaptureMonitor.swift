#if os(macOS)
import ApplicationServices
import CoreGraphics
import Foundation

/// Global capture toggle shortcuts, active only while a Studio performance
/// session runs. Escape remains reserved for emergency stop.
public enum PerformanceCaptureShortcut: String, CaseIterable, Identifiable, Sendable {
    case controlOptionM = "⌃⌥M"
    case controlOptionK = "⌃⌥K"
    case controlOptionP = "⌃⌥P"
    case controlOptionT = "⌃⌥T"

    public var id: String { rawValue }

    var virtualKeyCode: Int64 {
        switch self {
        case .controlOptionM: return 46
        case .controlOptionK: return 40
        case .controlOptionP: return 35
        case .controlOptionT: return 17
        }
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
    private var shortcut: PerformanceCaptureShortcut = .controlOptionM
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
            let flags = event.flags
            let matches = keyCode == currentShortcut.virtualKeyCode &&
                flags.contains(.maskControl) && flags.contains(.maskAlternate) &&
                !flags.contains(.maskCommand) && !flags.contains(.maskShift)
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
