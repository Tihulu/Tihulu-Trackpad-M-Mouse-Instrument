#if os(macOS)
import Foundation
import IOKit.hid

/// Optional, read-only MacBook lid-angle HID adapter. It is NOT a standard
/// Apple API and is enabled only by explicit user action. No persistent raw HID
/// report logging, no vendor-specific report writes, no polling on startup.
///
/// The device signature used here (Apple 0x05AC / 0x8104, HID sensor usage page
/// 0x20, usage 0x8A, feature report 1) was documented by the open-source
/// LidAngleSensor project by Sam Gold (Apache-2.0); see attribution docs.
@MainActor
final class MacBookHingeAngleSource {
    private let noOptions = IOOptionBits(kIOHIDOptionsTypeNone)
    private var manager: IOHIDManager?
    private var device: IOHIDDevice?
    private var timer: Timer?
    private(set) var status = "Not detected"
    var onAngle: ((Double) -> Void)?

    func start() -> Bool {
        stop()
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, noOptions)
        let filter: [String: Any] = [
            kIOHIDVendorIDKey as String: 0x05AC,
            kIOHIDProductIDKey as String: 0x8104,
            "UsagePage": 0x0020,
            "Usage": 0x008A
        ]
        IOHIDManagerSetDeviceMatching(manager, filter as CFDictionary)
        guard IOHIDManagerOpen(manager, noOptions) == kIOReturnSuccess else {
            status = "Cannot open HID manager · manual simulator available"
            return false
        }

        let devices = (IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>) ?? []
        for candidate in devices {
            guard IOHIDDeviceOpen(candidate, noOptions) == kIOReturnSuccess else {
                continue
            }
            if let firstAngle = readAngle(from: candidate) {
                self.manager = manager
                self.device = candidate
                status = "Sensor found · live"
                onAngle?(firstAngle)
                timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                    Task { @MainActor in self?.poll() }
                }
                return true
            }
            IOHIDDeviceClose(candidate, noOptions)
        }

        IOHIDManagerClose(manager, noOptions)
        status = devices.isEmpty
            ? "No compatible lid-angle HID sensor exposed · use simulator"
            : "Lid-angle HID device found but unsupported report · use simulator"
        return false
    }

    private func readAngle(from candidate: IOHIDDevice) -> Double? {
        var report = [UInt8](repeating: 0, count: 8)
        var length = CFIndex(report.count)
        let result = IOHIDDeviceGetReport(
            candidate, kIOHIDReportTypeFeature, 1, &report, &length
        )
        guard result == kIOReturnSuccess, length >= 3 else { return nil }
        let value = Double(UInt16(report[2]) << 8 | UInt16(report[1]))
        // Reject physically implausible values so unsupported sensor reports
        // can never trigger extreme pitch/CC transitions.
        return value.isFinite && (5...175).contains(value) ? value : nil
    }

    private func poll() {
        guard let device else { return }
        guard let angle = readAngle(from: device) else { return }
        onAngle?(angle)
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        if let device { IOHIDDeviceClose(device, noOptions) }
        if let manager { IOHIDManagerClose(manager, noOptions) }
        device = nil
        manager = nil
    }
}
#endif
