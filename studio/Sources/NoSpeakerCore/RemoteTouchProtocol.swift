import Foundation

public enum RemoteTouchError: Error, Equatable {
    case invalidFrame, invalidPairing, unavailable, capacity
}

/// V1 touch, V2 relative orientation and V3 inertial streams. Clients cannot specify MIDI targets or clocks.
public struct RemoteTouchFrame: Decodable, Equatable, Sendable {
    public enum Kind: String, Decodable, Sendable {
        case touch, release, heartbeat, orientationArm, orientation, motionRelease
        case accelerationArm, acceleration, accelerationRelease, rotationArm, rotation, rotationRelease
        case drumPads, pianoKeys, pedalboard, capabilities, mapping
    }
    public let version: Int
    public let sequence: UInt64
    public let kind: Kind
    public let page: Int?
    public let mask: Int?
    public let levels: [Double]?
    public let x: Double?
    public let y: Double?
    public let z: Double?
    var inertialValue: Double? {
        guard let x, let y, let z else { return nil }
        switch kind {
        case .accelerationArm, .acceleration: return RemoteMotionNormalizer.acceleration(x: x, y: y, z: z)
        case .rotationArm, .rotation: return RemoteMotionNormalizer.rotationRate(x: x, y: y, z: z)
        default: return nil
        }
    }
    public let alpha: Double?
    public let beta: Double?
    public let gamma: Double?
    public var angles: RemoteOrientation? {
        guard let alpha, let beta, let gamma else { return nil }
        return RemoteOrientation(alpha: alpha, beta: beta, gamma: gamma)
    }
    public static let maximumBytes = 256

    public static func read(_ bytes: Data) throws -> Self {
        guard !bytes.isEmpty, bytes.count <= maximumBytes,
              let keys = RemoteFlatJSON.uniqueKeys(bytes),
              let frame = try? JSONDecoder().decode(Self.self, from: bytes),
              (1...9_007_199_254_740_991).contains(frame.sequence)
        else { throw RemoteTouchError.invalidFrame }
        let common: Set<String> = ["version","sequence","kind"]
        switch frame.kind {
        case .touch:
            guard frame.version == 1, keys == common.union(["x","y"]), let x = frame.x, let y = frame.y,
                  x.isFinite, y.isFinite, (0...1).contains(x), (0...1).contains(y)
            else { throw RemoteTouchError.invalidFrame }
        case .release, .heartbeat:
            guard frame.version == 1, keys == common else { throw RemoteTouchError.invalidFrame }
        case .orientationArm, .orientation:
            guard frame.version == 2, keys == common.union(["alpha","beta","gamma"]),
                  let angles = frame.angles, abs(angles.beta) <= 80, abs(angles.gamma) <= 80
            else { throw RemoteTouchError.invalidFrame }
        case .motionRelease:
            guard frame.version == 2, keys == common else { throw RemoteTouchError.invalidFrame }
        case .accelerationArm, .acceleration, .rotationArm, .rotation:
            guard frame.version == 3, keys == common.union(["x","y","z"]), frame.inertialValue != nil
            else { throw RemoteTouchError.invalidFrame }
        case .accelerationRelease, .rotationRelease:
            guard frame.version == 3, keys == common else { throw RemoteTouchError.invalidFrame }
        case .drumPads:
            guard frame.version == 4, keys == common.union(["mask"]), let mask = frame.mask,
                  (0...255).contains(mask) else { throw RemoteTouchError.invalidFrame }
        case .pianoKeys:
            guard frame.version == 5, keys == common.union(["mask"]), let mask = frame.mask,
                  (0...RemotePiano.maximumMask).contains(mask) else { throw RemoteTouchError.invalidFrame }
        case .capabilities:
            guard frame.version == 7, keys == common else { throw RemoteTouchError.invalidFrame }
        case .mapping:
            guard frame.version == 8, bytes.allSatisfy({ $0 < 128 }), keys == common.union(["page"]),
                  let page = frame.page, (0..<8).contains(page) else { throw RemoteTouchError.invalidFrame }
        case .pedalboard:
            guard frame.version == 6, keys == common.union(["mask","levels"]),
                  let mask = frame.mask, let levels = frame.levels,
                  RemotePedalboard.validSnapshot(mask: mask, levels: levels) else { throw RemoteTouchError.invalidFrame }
        }
        return frame
    }
}

/// Host transport must supply a fresh 32-byte OS CSPRNG secret.
/// No listener, encryption or random generation is provided by this core.
struct RemotePairingGate: Sendable {
    private var pending: Data?
    private var source: SensorSource?
    private var issuedAt = 0.0
    private var mappingDetails = false
    mutating func issue(secret: Data, source: SensorSource, now: Double, mappingDetails: Bool = false) throws {
        guard secret.count == 32, source == .phone || source == .tablet,
              now.isFinite, now >= 0 else { throw RemoteTouchError.invalidPairing }
        pending = secret
        self.source = source
        self.mappingDetails = mappingDetails
        issuedAt = now
    }
    mutating func consume(secret: Data, now: Double) throws -> SensorSource {
        try consumeWithConsent(secret:secret,now:now).source
    }
    mutating func consumeWithConsent(secret: Data, now: Double) throws -> (source: SensorSource, mappingDetails: Bool) {
        guard let pending, let source, now.isFinite, now >= issuedAt,
              now-issuedAt < 60 else {
            clear()
            throw RemoteTouchError.invalidPairing
        }
        guard secret.count == 32 else { throw RemoteTouchError.invalidPairing }
        var difference: UInt8 = 0
        for (a,b) in zip(pending,secret) { difference |= a ^ b }
        guard difference == 0 else { throw RemoteTouchError.invalidPairing }
        let consent = mappingDetails
        clear()
        return (source,consent)
    }
    mutating func clear() { pending = nil; source = nil; issuedAt = 0; mappingDetails = false }
}

struct RemoteInertialStream: Sendable {
    var lastReceipt: Double
    var session: UUID?
    var strikeDetector = AirStrikeDetector()
    var strikeReleaseAt: Double?
    func expired(now: Double) -> Bool {
        !now.isFinite || now < lastReceipt || now-lastReceipt >= 0.35
    }
}

struct RemoteTouchPeer: Sendable {
    let source: SensorSource
    let mappingDetails: Bool
    var capabilitiesSeen = false
    var performanceStarted = false
    var mappingStarted: Double?
    var mappingLast: Double?
    var mappingNext = 0
    var mappingComplete = false
    var routerSession: UUID?
    var drumSession: UUID?
    var drumMask = 0
    var lastDrumReceipt: Double?
    var pianoSession: UUID?
    var pianoMask = 0
    var lastPianoReceipt: Double?
    var pedalSession: UUID?
    var pedalMask = 0
    var lastPedalReceipt: Double?
    var motionSession: UUID?
    var tilt: RemoteTiltCalibration?
    var motionFreshness = RemoteMotionFreshness()
    var lastTouch: Double?
    var lastOrientation: Double?
    var inertial: [SensorSignal: RemoteInertialStream] = [:]
    private var lastSeen: Double
    private var lastSequence: UInt64 = 0
    private var windowStart: Double
    private var count = 0
    init(source: SensorSource, now: Double, mappingDetails: Bool = false) {
        self.source = source
        self.mappingDetails = mappingDetails
        lastSeen = now
        windowStart = now
    }
    func expired(now: Double) -> Bool {
        guard now.isFinite, now >= lastSeen, now-lastSeen < 2 else { return true }
        if let started = mappingStarted, !mappingComplete, now-started >= 10 { return true }
        // Neither stream may extend the other's lifetime. Fail closed for the
        // whole connection on an expired active stream; explicit release is independent.
        if routerSession != nil {
            guard let lastTouch, now >= lastTouch, now-lastTouch < 0.35 else { return true }
        }
        if tilt != nil {
            guard let lastOrientation, now >= lastOrientation, now-lastOrientation < 0.35 else { return true }
        }
        if inertial.values.contains(where: { $0.expired(now: now) }) { return true }
        if drumSession != nil {
            guard let lastDrumReceipt, now >= lastDrumReceipt, now-lastDrumReceipt < 0.35 else { return true }
        }
        if pianoSession != nil {
            guard let lastPianoReceipt, now >= lastPianoReceipt, now-lastPianoReceipt < 0.35 else { return true }
        }
        if pedalSession != nil {
            guard let lastPedalReceipt, now >= lastPedalReceipt, now-lastPedalReceipt < 0.35 else { return true }
        }
        return false
    }
    var isIdle: Bool { routerSession == nil && tilt == nil && inertial.isEmpty && drumSession == nil && pianoSession == nil && pedalSession == nil }
    mutating func accept(_ frame: RemoteTouchFrame, now: Double) -> Bool {
        guard !expired(now: now), frame.sequence > lastSequence,
              (frame.kind != .heartbeat && frame.kind != .capabilities && frame.kind != .mapping) || isIdle else { return false }
        if now-windowStart >= 1 { windowStart = now; count = 0 }
        guard count < 90 else { return false }
        count += 1
        lastSequence = frame.sequence
        lastSeen = now
        return true
    }
}

public enum RemoteTouchResult: Equatable, Sendable {
    case accepted([SensorCommand])
    case close([SensorCommand])
}
