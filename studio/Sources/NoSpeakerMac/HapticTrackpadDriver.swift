#if os(macOS)
import Foundation
import CoreFoundation
import Darwin
import os.lock
import NoSpeakerCore

public enum HapticDriverError: LocalizedError {
    case frameworkUnavailable
    case symbolsUnavailable
    case noTrackpad
    case noHapticTrackpad
    case actuatorOpenFailed

    public var errorDescription: String? {
        switch self {
        case .frameworkUnavailable: return "macOS MultitouchSupport is unavailable."
        case .symbolsUnavailable: return "The required private trackpad functions are unavailable on this macOS version."
        case .noTrackpad: return "No compatible trackpad was found."
        case .noHapticTrackpad: return "A trackpad was found, but its haptic actuator could not be opened."
        case .actuatorOpenFailed: return "The trackpad haptic actuator could not be opened."
        }
    }
}

public struct TrackpadContact: Sendable, Equatable {
    public var isDown: Bool
    public var x: Float
    public var y: Float
    public var size: Float

    public init(isDown: Bool = false, x: Float = 0, y: Float = 0, size: Float = 0) {
        self.isDown = isDown
        self.x = x
        self.y = y
        self.size = size
    }
}

private typealias CreateList = @convention(c) () -> Unmanaged<CFArray>?
private typealias GetID = @convention(c) (UnsafeMutableRawPointer, UnsafeMutablePointer<UInt64>) -> Int32
private typealias IsBuiltIn = @convention(c) (UnsafeMutableRawPointer) -> Bool
private typealias ActuatorCreate = @convention(c) (UInt64) -> Unmanaged<CFTypeRef>?
private typealias ActuatorOpen = @convention(c) (CFTypeRef) -> Int32
private typealias ActuatorClose = @convention(c) (CFTypeRef) -> Int32
private typealias ActuationCreate = @convention(c) (CFDictionary, Int32) -> UnsafeMutableRawPointer?
private typealias ActuationPlay = @convention(c) (UnsafeMutableRawPointer, UnsafeMutableRawPointer, UInt32, Float, Float) -> Int32
private typealias FrameCallback = @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, Int32, Double, Int32) -> Int32
private typealias RegisterCallback = @convention(c) (UnsafeMutableRawPointer, FrameCallback) -> Void
private typealias DeviceStart = @convention(c) (UnsafeMutableRawPointer, Int32) -> Void
private typealias DeviceStop = @convention(c) (UnsafeMutableRawPointer) -> Void

private final class TouchBridge: @unchecked Sendable {
    static let shared = TouchBridge()
    private var lock = os_unfair_lock()
    private var handler: (@Sendable (TrackpadContact) -> Void)?

    func setHandler(_ handler: (@Sendable (TrackpadContact) -> Void)?) {
        os_unfair_lock_lock(&lock)
        self.handler = handler
        os_unfair_lock_unlock(&lock)
    }

    func emit(_ contact: TrackpadContact) {
        os_unfair_lock_lock(&lock)
        let callback = handler
        os_unfair_lock_unlock(&lock)
        callback?(contact)
    }
}

private let trackpadFrameCallback: FrameCallback = { _, data, count, _, _ in
    var best = TrackpadContact()
    if let data, count > 0 {
        for index in 0..<Int(count) {
            // Record layout and state values intentionally mirror os6/nospeaker v1.0.
            let record = data.advanced(by: index * 96)
            let state = record.load(fromByteOffset: 20, as: Int32.self)
            guard (3...5).contains(state) else { continue }
            best = TrackpadContact(
                isDown: true,
                x: record.load(fromByteOffset: 32, as: Float.self),
                y: record.load(fromByteOffset: 36, as: Float.self),
                size: record.load(fromByteOffset: 48, as: Float.self)
            )
        }
    }
    TouchBridge.shared.emit(best)
    return 0
}

/// Force Touch output backend derived from the hardware path in os6/nospeaker v1.0
/// by Cody Collier, licensed under MIT. Studio adds locking, safety policy and
/// reusable lifecycle APIs while keeping the private-framework semantics close to upstream.
public final class HapticTrackpadDriver: @unchecked Sendable {
    private let safety: HapticSafetyPolicy
    private let stateLock = NSLock()
    private var framework: UnsafeMutableRawPointer?
    private var deviceList: CFArray?
    private var motorDeviceID: UInt64 = 0
    private var motor: CFTypeRef?
    private var motorPointer: UnsafeMutableRawPointer?
    private var touchDevicesInUse: [UnsafeMutableRawPointer] = []

    private var createList: CreateList?
    private var getID: GetID?
    private var deviceIsBuiltIn: IsBuiltIn?
    private var actuatorCreate: ActuatorCreate?
    private var actuatorOpen: ActuatorOpen?
    private var actuatorClose: ActuatorClose?
    private var actuationCreate: ActuationCreate?
    private var actuationPlay: ActuationPlay?
    private var registerCallback: RegisterCallback?
    private var unregisterCallback: RegisterCallback?
    private var deviceStart: DeviceStart?
    private var deviceStop: DeviceStop?

    public private(set) var isOpen = false
    public private(set) var isBuiltIn = false

    public init(safety: HapticSafetyPolicy = .init()) throws {
        self.safety = safety
        try loadFramework()
    }

    deinit {
        close()
        if let framework { dlclose(framework) }
    }

    private func symbol<T>(_ name: String, as: T.Type) -> T? {
        guard let framework, let raw = dlsym(framework, name) else { return nil }
        return unsafeBitCast(raw, to: T.self)
    }

    private func loadFramework() throws {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport", RTLD_NOW) else {
            throw HapticDriverError.frameworkUnavailable
        }
        framework = handle
        createList = symbol("MTDeviceCreateList", as: CreateList.self)
        getID = symbol("MTDeviceGetDeviceID", as: GetID.self)
        deviceIsBuiltIn = symbol("MTDeviceIsBuiltIn", as: IsBuiltIn.self)
        actuatorCreate = symbol("MTActuatorCreateFromDeviceID", as: ActuatorCreate.self)
        actuatorOpen = symbol("MTActuatorOpen", as: ActuatorOpen.self)
        actuatorClose = symbol("MTActuatorClose", as: ActuatorClose.self)
        actuationCreate = symbol("MTActuationCreateFromDictionary", as: ActuationCreate.self)
        actuationPlay = symbol("MTActuationActuate", as: ActuationPlay.self)
        registerCallback = symbol("MTRegisterContactFrameCallback", as: RegisterCallback.self)
        unregisterCallback = symbol("MTUnregisterContactFrameCallback", as: RegisterCallback.self)
        deviceStart = symbol("MTDeviceStart", as: DeviceStart.self)
        deviceStop = symbol("MTDeviceStop", as: DeviceStop.self)

        guard createList != nil, getID != nil, actuatorCreate != nil, actuatorOpen != nil,
              actuationCreate != nil, actuationPlay != nil else {
            throw HapticDriverError.symbolsUnavailable
        }
    }

    public func open() throws {
        stateLock.lock()
        defer { stateLock.unlock() }
        if isOpen { return }
        guard let createList, let getID, let actuatorCreate, let actuatorOpen else { throw HapticDriverError.symbolsUnavailable }
        guard let list = createList()?.takeRetainedValue(), CFArrayGetCount(list) > 0 else { throw HapticDriverError.noTrackpad }
        deviceList = list

        var devices: [(id: UInt64, builtIn: Bool)] = []
        for index in 0..<CFArrayGetCount(list) {
            guard let raw = CFArrayGetValueAtIndex(list, index) else { continue }
            let device = UnsafeMutableRawPointer(mutating: raw)
            var id: UInt64 = 0
            if getID(device, &id) == 0 {
                devices.append((id, deviceIsBuiltIn?(device) ?? false))
            }
        }
        guard !devices.isEmpty else { throw HapticDriverError.noTrackpad }

        for device in devices.sorted(by: { $0.builtIn && !$1.builtIn }) {
            if let ref = actuatorCreate(device.id)?.takeRetainedValue(), actuatorOpen(ref) == 0 {
                motor = ref
                motorPointer = Unmanaged.passUnretained(ref as AnyObject).toOpaque()
                motorDeviceID = device.id
                isBuiltIn = device.builtIn
                isOpen = true
                return
            }
        }
        throw HapticDriverError.noHapticTrackpad
    }

    public func close() {
        stateLock.lock()
        defer { stateLock.unlock() }
        stopTouchLocked()
        if let motor { _ = actuatorClose?(motor) }
        motor = nil
        motorPointer = nil
        deviceList = nil
        motorDeviceID = 0
        isOpen = false
    }

    public func panicStop() {
        close()
    }

    public func play(_ inputFrame: HapticFrame, masterLevel: Double = 1) throws {
        if !isOpen { try open() }
        stateLock.lock()
        defer { stateLock.unlock() }
        guard let motorPointer, let actuationCreate, let actuationPlay else { throw HapticDriverError.actuatorOpenFailed }

        var frame = safety.clamp(inputFrame)
        frame.level = min(1, max(0, frame.level * masterLevel))
        guard frame.level > 0, !frame.tones.isEmpty else { return }
        let amplitudeSum = max(0.0001, frame.tones.reduce(0) { $0 + max(0, $1.amplitude) })
        let shape: [String: Any] = [
            "BaseWaveform": ["Type": "Gaussian", "Amplitude": 0.0, "DurationMS": frame.durationMS],
            "Tones": frame.tones.map { tone in
                [
                    "Type": "Sine",
                    "Amplitude": max(0, tone.amplitude) / amplitudeSum,
                    "DurationMS": frame.durationMS,
                    "DelayMS": 0.0,
                    "FrequencykHz": tone.frequencyHz / 1_000.0
                ] as [String: Any]
            }
        ]
        guard let actuation = actuationCreate(shape as CFDictionary, 0) else { return }
        _ = actuationPlay(actuation, motorPointer, 0, Float(frame.level), 0)
        Unmanaged<AnyObject>.fromOpaque(actuation).release()
    }

    public func startTouch(handler: @escaping @Sendable (TrackpadContact) -> Void) throws {
        if !isOpen { try open() }
        stateLock.lock()
        defer { stateLock.unlock() }
        guard let deviceList, let getID, let registerCallback, let deviceStart else { throw HapticDriverError.symbolsUnavailable }
        stopTouchLocked()
        var devices: [UnsafeMutableRawPointer] = []
        for index in 0..<CFArrayGetCount(deviceList) {
            guard let raw = CFArrayGetValueAtIndex(deviceList, index) else { continue }
            let device = UnsafeMutableRawPointer(mutating: raw)
            var id: UInt64 = 0
            if getID(device, &id) == 0, id == motorDeviceID { devices.append(device) }
        }
        guard !devices.isEmpty else { throw HapticDriverError.noTrackpad }
        TouchBridge.shared.setHandler(handler)
        for device in devices {
            registerCallback(device, trackpadFrameCallback)
            deviceStart(device, 0)
        }
        touchDevicesInUse = devices
    }

    public func stopTouch() {
        stateLock.lock()
        defer { stateLock.unlock() }
        stopTouchLocked()
    }

    private func stopTouchLocked() {
        for device in touchDevicesInUse {
            unregisterCallback?(device, trackpadFrameCallback)
            deviceStop?(device)
        }
        touchDevicesInUse.removeAll()
        TouchBridge.shared.setHandler(nil)
    }
}
#endif
