#if os(macOS)
import Foundation
import ApplicationServices
import CoreGraphics
import CoreFoundation

public enum CaptureHotkey: String, CaseIterable, Identifiable, Sendable {
    case f6 = "F6"
    case f7 = "F7"
    case f8 = "F8"
    case f9 = "F9"

    public var id: String { rawValue }

    public var keyCode: Int64 {
        switch self {
        case .f6: return 97
        case .f7: return 98
        case .f8: return 100
        case .f9: return 101
        }
    }

    public var displayText: String { "Control + Option + \(rawValue)" }
}

public enum InputCaptureError: LocalizedError {
    case accessibilityRequired
    case eventTapUnavailable

    public var errorDescription: String? {
        switch self {
        case .accessibilityRequired:
            return "To capture mouse events or detect physical clicks globally, allow NoSpeaker Studio in System Settings → Privacy & Security → Accessibility, then enable Input Controls again."
        case .eventTapUnavailable:
            return "macOS could not create the input event tap. Disable capture and check Accessibility/Input Monitoring permissions."
        }
    }
}

private let expressiveInputTapCallback: CGEventTapCallBack = { _, type, event, userInfo in
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let service = Unmanaged<ExpressiveInputCapture>.fromOpaque(userInfo).takeUnretainedValue()
    return service.handle(type: type, event: event)
}

/// Opt-in global hotkey + pointer suppression. Unlike NSEvent's global monitor,
/// a CoreGraphics event tap may consume mouse motion while the input is captured.
///
/// Safety requirements:
/// - OFF by default, never request permissions on startup.
/// - Fail closed if Accessibility is unavailable.
/// - ESC stops all activity even when a DAW is focused, while the tap is active.
/// - Capture key restores normal pointer behavior before cancelling MIDI.
/// - macOS automatically destroys this event tap when the app quits/crashes.
public final class ExpressiveInputCapture: @unchecked Sendable {
    private let stateLock = NSLock()
    private var port: CFMachPort?
    private var source: CFRunLoopSource?
    private var captured = false
    private var hotkey: CaptureHotkey = .f8

    public var onCaptureChanged: (@Sendable (Bool) -> Void)?
    public var onPanic: (@Sendable () -> Void)?
    public var onPhysicalClick: (@Sendable (Bool) -> Void)?
    public var onTapDisabled: (@Sendable () -> Void)?

    public init() {}
    deinit { stop() }

    public var isCaptured: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return captured
    }

    public var isInstalled: Bool { port != nil }

    public func setHotkey(_ hotkey: CaptureHotkey) {
        stateLock.lock()
        self.hotkey = hotkey
        stateLock.unlock()
    }

    public func install() throws {
        if let port {
            CGEvent.tapEnable(tap: port, enable: true)
            return
        }
        guard AXIsProcessTrusted() else { throw InputCaptureError.accessibilityRequired }

        let eventTypes: [CGEventType] = [
            .keyDown, .keyUp, .mouseMoved, .leftMouseDragged, .rightMouseDragged,
            .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .scrollWheel
        ]
        let mask = eventTypes.reduce(CGEventMask(0)) {
            $0 | (CGEventMask(1) << CGEventMask($1.rawValue))
        }
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: expressiveInputTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            throw InputCaptureError.eventTapUnavailable
        }
        let runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        port = tap
        source = runLoopSource
    }

    public func setCaptured(_ enabled: Bool) {
        guard port != nil || !enabled else { return }
        stateLock.lock()
        let changed = captured != enabled
        captured = enabled
        stateLock.unlock()
        if changed { onCaptureChanged?(enabled) }
    }

    public func stop() {
        setCaptured(false)
        if let source {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        if let port { CFMachPortInvalidate(port) }
        source = nil
        port = nil
    }

    fileprivate func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            setCaptured(false)
            onTapDisabled?()
            return Unmanaged.passUnretained(event)
        }

        stateLock.lock()
        let currentHotkey = hotkey
        let active = captured
        stateLock.unlock()

        if type == .keyDown || type == .keyUp {
            let key = event.getIntegerValueField(.keyboardEventKeycode)
            // Escape is always the kill switch while global controls are armed.
            if key == 53 {
                if type == .keyDown {
                    setCaptured(false)
                    onPanic?()
                }
                return nil
            }
            let flags = event.flags
            if key == currentHotkey.keyCode &&
                flags.contains(.maskControl) && flags.contains(.maskAlternate) {
                if type == .keyDown &&
                    event.getIntegerValueField(.keyboardEventAutorepeat) == 0 {
                    setCaptured(!active)
                }
                return nil
            }
            return Unmanaged.passUnretained(event)
        }

        if type == .leftMouseDown || type == .leftMouseUp {
            onPhysicalClick?(type == .leftMouseDown)
        }

        if active {
            switch type {
            case .mouseMoved, .leftMouseDragged, .rightMouseDragged,
                 .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp,
                 .scrollWheel:
                return nil
            default: break
            }
        }
        return Unmanaged.passUnretained(event)
    }
}
#endif
