#if os(macOS)
import Foundation
import IOKit.hid
import NoSpeakerCore

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
    var onAngle: ((Double,Double) -> Void)?
    var onLoss: ((String) -> Void)?
    private var lastValidSample: TimeInterval = 0
    private var readDiagnostic = "No report read"
    private var pollGeneration: UInt64 = 0

    func start() -> Bool {
        stop()
        readDiagnostic = "No report read"
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, noOptions)
        let filter: [String: Any] = [
            kIOHIDVendorIDKey as String: 0x05AC,
            kIOHIDProductIDKey as String: 0x8104,
            "UsagePage": 0x0020,
            "Usage": 0x008A
        ]
        IOHIDManagerSetDeviceMatching(manager, filter as CFDictionary)
        let openResult = IOHIDManagerOpen(manager, noOptions)
        guard openResult == kIOReturnSuccess else {
            status = "Cannot open HID manager (\(openResult)) · manual simulator available"
            return false
        }

        let devices = (IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>) ?? []
        for candidate in devices {
            let result = IOHIDDeviceOpen(candidate, noOptions)
            guard result == kIOReturnSuccess else {
                readDiagnostic = "Device open failed (\(result))"
                continue
            }
            let receipt = ProcessInfo.processInfo.systemUptime
            if let firstAngle = readAngle(from: candidate),
               PhysicalPatchRuntime.admitsPhysicalReceipt(receipt,now:ProcessInfo.processInfo.systemUptime) {
                self.manager = manager
                self.device = candidate
                status = "Sensor found · " + readDiagnostic
                lastValidSample = receipt
                let generation = pollGeneration
                timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                    Task { @MainActor in
                        guard let self, self.pollGeneration == generation else { return }
                        self.poll()
                    }
                }
                onAngle?(firstAngle,receipt)
                return device != nil
            }
            IOHIDDeviceClose(candidate, noOptions)
        }

        IOHIDManagerClose(manager, noOptions)
        status = devices.isEmpty
            ? "No compatible lid-angle HID sensor exposed · use simulator"
            : "Lid-angle HID device found but unsupported report · " + readDiagnostic
        return false
    }

    private func readAngle(from candidate: IOHIDDevice) -> Double? {
        var report = [UInt8](repeating: 0, count: 8)
        var length = CFIndex(report.count)
        let result = IOHIDDeviceGetReport(
            candidate, kIOHIDReportTypeFeature, 1, &report, &length
        )
        readDiagnostic = "Feature report 1: result \(result), length \(length)"
        guard result == kIOReturnSuccess, length >= 3, length <= report.count else { return nil }
        let value = Double(UInt16(report[2]) << 8 | UInt16(report[1]))
        // Reject physically implausible values so unsupported sensor reports
        // can never trigger extreme pitch/CC transitions.
        guard value.isFinite, (5...175).contains(value) else {
            readDiagnostic += " · angle candidate \(Int(value)) outside supported range"
            return nil
        }
        readDiagnostic += " · plausible angle"
        return value
    }

    private func poll() {
        guard let device else { return }
        let receipt = ProcessInfo.processInfo.systemUptime
        let angle = readAngle(from:device)
        let now = ProcessInfo.processInfo.systemUptime
        // A successful but blocking read cannot renew an expired lease.
        if let angle,PhysicalPatchRuntime.admitsPhysicalReceipt(receipt,now:now),
           PhysicalPatchRuntime.admitsPhysicalReceipt(lastValidSample,now:now) {
            lastValidSample = receipt
            onAngle?(angle,receipt)
        } else if !PhysicalPatchRuntime.admitsPhysicalReceipt(lastValidSample,now:now) ||
                  !PhysicalPatchRuntime.admitsPhysicalReceipt(receipt,now:now) {
            let reason = "Lid signal lost · " + readDiagnostic
            stop()
            status = reason
            onLoss?(reason)
        }
    }

    func stop() {
        pollGeneration &+= 1
        timer?.invalidate()
        timer = nil
        if let device { IOHIDDeviceClose(device, noOptions) }
        if let manager { IOHIDManagerClose(manager, noOptions) }
        device = nil
        manager = nil
    }
}
#endif
