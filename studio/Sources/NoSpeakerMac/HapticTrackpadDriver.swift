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
    case actuationCreationFailed

    public var errorDescription: String? {
        switch self {
        case .frameworkUnavailable: return "macOS MultitouchSupport is unavailable."
        case .symbolsUnavailable: return "The required private trackpad functions are unavailable on this macOS version."
        case .noTrackpad: return "No compatible trackpad was found."
        case .noHapticTrackpad: return "A trackpad was found, but its haptic actuator could not be opened."
        case .actuatorOpenFailed: return "The trackpad haptic actuator could not be opened."
        case .actuationCreationFailed: return "The trackpad framework could not create a haptic frame."
        }
    }
}

public enum TouchSurfaceKind: String, CaseIterable, Identifiable, Sendable, Hashable {
    case trackpad = "Trackpad"
    case magicMouse = "Magic Mouse"

    public var id: String { rawValue }
}

public struct SurfaceContact: Sendable, Equatable, Identifiable {
    public var id: Int
    public var surface: TouchSurfaceKind
    public var state: Int
    public var isDown: Bool
    public var x: Float
    public var y: Float
    public var size: Float

    public init(
        id: Int,
        surface: TouchSurfaceKind,
        state: Int,
        isDown: Bool,
        x: Float,
        y: Float,
        size: Float
    ) {
        self.id = id
        self.surface = surface
        self.state = state
        self.isDown = isDown
        self.x = x
        self.y = y
        self.size = size
    }
}

public struct SurfaceTouchFrame: Sendable, Equatable {
    public var surface: TouchSurfaceKind
    public var contacts: [SurfaceContact]
    public var timestamp: Double
    public var frameNumber: Int

    public init(
        surface: TouchSurfaceKind,
        contacts: [SurfaceContact],
        timestamp: Double,
        frameNumber: Int
    ) {
        self.surface = surface
        self.contacts = contacts
        self.timestamp = timestamp
        self.frameNumber = frameNumber
    }
}

public struct TrackpadContact: Sendable, Equatable {
    public var id: Int
    public var isDown: Bool
    public var x: Float
    public var y: Float
    public var size: Float

    public init(id: Int = 0, isDown: Bool = false, x: Float = 0, y: Float = 0, size: Float = 0) {
        self.id = id
        self.isDown = isDown
        self.x = x
        self.y = y
        self.size = size
    }

    public init(_ contact: SurfaceContact) {
        self.init(id: contact.id, isDown: contact.isDown, x: contact.x, y: contact.y, size: contact.size)
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
    private var handler: (@Sendable (SurfaceTouchFrame) -> Void)?
    private var surfaceByDevice: [UInt: TouchSurfaceKind] = [:]

    func configure(
        surfaces: [UnsafeMutableRawPointer: TouchSurfaceKind],
        handler: (@Sendable (SurfaceTouchFrame) -> Void)?
    ) {
        os_unfair_lock_lock(&lock)
        self.handler = handler
        surfaceByDevice = Dictionary(uniqueKeysWithValues: surfaces.map {
            (UInt(bitPattern: $0.key), $0.value)
        })
        os_unfair_lock_unlock(&lock)
    }

    func clear() {
        os_unfair_lock_lock(&lock)
        handler = nil
        surfaceByDevice.removeAll()
        os_unfair_lock_unlock(&lock)
    }

    func emit(
        device: UnsafeMutableRawPointer?,
        data: UnsafeMutableRawPointer?,
        count: Int32,
        timestamp: Double,
        frame: Int32
    ) {
        os_unfair_lock_lock(&lock)
        let callback = handler
        let surface = device.flatMap { surfaceByDevice[UInt(bitPattern: $0)] }
        os_unfair_lock_unlock(&lock)

        // Never attribute an unregistered callback to the Trackpad.
        guard let surface, let callback else { return }
        let decision = NativeTouchFramePolicy.decision(knownDevice:true,count:Int(count),hasData:data != nil)
        var contacts: [SurfaceContact] = []
        if case let .decode(contactCount) = decision, let data {
            contacts.reserveCapacity(contactCount)
            for index in 0..<contactCount {
                // Canonical 96-byte MTTouch layout used by the existing upstream-derived path.
                let record = data.advanced(by: index * 96)
                let pathIndex = Int(record.load(fromByteOffset: 16, as: Int32.self))
                let state = Int(record.load(fromByteOffset: 20, as: Int32.self))
                guard (3...5).contains(state) else { continue }
                contacts.append(.init(
                    id: pathIndex,
                    surface: surface,
                    state: state,
                    isDown: state != 5,
                    x: record.load(fromByteOffset: 32, as: Float.self),
                    y: record.load(fromByteOffset: 36, as: Float.self),
                    size: record.load(fromByteOffset: 48, as: Float.self)
                ))
            }
        }

        // Empty or malformed known-device envelopes release this surface
        // instead of reading outside the bounded native contact array.
        callback(.init(
            surface: surface,
            contacts: contacts,
            timestamp: timestamp,
            frameNumber: Int(frame)
        ))
    }
}

private let trackpadFrameCallback: FrameCallback = { device, data, count, timestamp, frame in
    TouchBridge.shared.emit(
        device: device,
        data: data,
        count: count,
        timestamp: timestamp,
        frame: frame
    )
    return 0
}

/// Force Touch output backend derived from the hardware path in os6/nospeaker v1.0
/// by Cody Collier, licensed under MIT. Studio adds locking, safety policy and
/// reusable lifecycle APIs while keeping the private-framework semantics close to upstream.
public final class HapticTrackpadDriver: @unchecked Sendable {
    private let safety: HapticSafetyPolicy
    private let lifetime = ActuatorLifetimeGate()
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

    private var opened = false
    private var builtIn = false
    public var isOpen: Bool { lifetime.snapshot { opened } }
    public var isBuiltIn: Bool { lifetime.snapshot { builtIn } }

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
        try lifetime.withActive { try openLocked() }
    }

    private func openLocked() throws {
        if opened { return }
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
                builtIn = device.builtIn
                opened = true
                return
            }
        }
        throw HapticDriverError.noHapticTrackpad
    }

    /// Closing is terminal for this instance. Reconnect constructs a new
    /// driver; an obsolete renderer cannot reopen a retired actuator.
    public func close() {
        lifetime.retire {
            // Never clear the process-wide touch bridge from a retired driver
            // that never owned a live monitoring session.
            if !touchDevicesInUse.isEmpty { stopTouchLocked() }
            if let motor { _ = actuatorClose?(motor) }
            motor = nil
            motorPointer = nil
            deviceList = nil
            motorDeviceID = 0
            opened = false
            builtIn = false
        }
    }

    public func panicStop() {
        close()
    }

    public func play(_ inputFrame: HapticFrame, masterLevel: Double = 1) throws {
        try lifetime.withActive {
            try openLocked()
            try playLocked(inputFrame, masterLevel: masterLevel)
        }
    }

    private func playLocked(_ inputFrame: HapticFrame, masterLevel: Double) throws {
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
        guard let actuation = actuationCreate(shape as CFDictionary, 0) else { throw HapticDriverError.actuationCreationFailed }
        _ = actuationPlay(actuation, motorPointer, 0, Float(frame.level), 0)
        Unmanaged<AnyObject>.fromOpaque(actuation).release()
    }

    public func startSurfaceMonitoring(
        includeExternalSurfaces: Bool = true,
        handler: @escaping @Sendable (SurfaceTouchFrame) -> Void
    ) throws {
        try lifetime.withActive {
            try openLocked()
            try startSurfaceMonitoringLocked(includeExternalSurfaces: includeExternalSurfaces, handler: handler)
        }
    }

    private func startSurfaceMonitoringLocked(
        includeExternalSurfaces: Bool,
        handler: @escaping @Sendable (SurfaceTouchFrame) -> Void
    ) throws {
        guard let deviceList, let getID, let registerCallback, let deviceStart else {
            throw HapticDriverError.symbolsUnavailable
        }

        stopTouchLocked()

        var selected: [UnsafeMutableRawPointer] = []
        var kinds: [UnsafeMutableRawPointer: TouchSurfaceKind] = [:]

        for index in 0..<CFArrayGetCount(deviceList) {
            guard let raw = CFArrayGetValueAtIndex(deviceList, index) else { continue }
            let device = UnsafeMutableRawPointer(mutating: raw)
            var id: UInt64 = 0
            guard getID(device, &id) == 0 else { continue }

            if id == motorDeviceID {
                selected.append(device)
                kinds[device] = .trackpad
            } else if includeExternalSurfaces, !(deviceIsBuiltIn?(device) ?? false) {
                selected.append(device)
                kinds[device] = .magicMouse
            }
        }

        guard !selected.isEmpty else { throw HapticDriverError.noTrackpad }

        TouchBridge.shared.configure(surfaces: kinds, handler: handler)
        for device in selected {
            registerCallback(device, trackpadFrameCallback)
            deviceStart(device, 0)
        }
        touchDevicesInUse = selected
    }

    public func startTouch(handler: @escaping @Sendable (TrackpadContact) -> Void) throws {
        try startSurfaceMonitoring(includeExternalSurfaces: false) { frame in
            guard frame.surface == .trackpad else { return }
            if let first = frame.contacts.first(where: { $0.isDown }) ?? frame.contacts.first {
                handler(TrackpadContact(first))
            } else {
                handler(TrackpadContact())
            }
        }
    }

    public func stopSurfaceMonitoring() {
        stopTouch()
    }

    public func stopTouch() {
        // Late cleanup from an old session must not clear the new owner's
        // process-wide bridge.
        try? lifetime.withActive {
            if !touchDevicesInUse.isEmpty { stopTouchLocked() }
        }
    }

    private func stopTouchLocked() {
        for device in touchDevicesInUse {
            unregisterCallback?(device, trackpadFrameCallback)
            deviceStop?(device)
        }
        touchDevicesInUse.removeAll()
        TouchBridge.shared.clear()
    }
}
#endif
