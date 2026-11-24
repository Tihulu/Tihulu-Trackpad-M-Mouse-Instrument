import Foundation

public enum RemoteTouchError: Error, Equatable {
    case invalidFrame, invalidPairing, unavailable, capacity
}

/// Versioned touch-only schema. Clients cannot specify MIDI targets or clocks.
public struct RemoteTouchFrame: Decodable, Equatable, Sendable {
    public enum Kind: String, Decodable, Sendable { case touch, release, heartbeat }
    public let version: Int
    public let sequence: UInt64
    public let kind: Kind
    public let x: Double?
    public let y: Double?
    public static let maximumBytes = 256

    public static func read(_ bytes: Data) throws -> Self {
        guard !bytes.isEmpty, bytes.count <= maximumBytes,
              let object = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any],
              let frame = try? JSONDecoder().decode(Self.self, from: bytes),
              frame.version == 1, (1...9_007_199_254_740_991).contains(frame.sequence)
        else { throw RemoteTouchError.invalidFrame }
        let keys = Set(object.keys)
        let common: Set<String> = ["version","sequence","kind"]
        switch frame.kind {
        case .touch:
            guard keys == common.union(["x","y"]), let x = frame.x, let y = frame.y,
                  x.isFinite, y.isFinite, (0...1).contains(x), (0...1).contains(y)
            else { throw RemoteTouchError.invalidFrame }
        case .release, .heartbeat:
            guard keys == common else { throw RemoteTouchError.invalidFrame }
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
    mutating func issue(secret: Data, source: SensorSource, now: Double) throws {
        guard secret.count == 32, source == .phone || source == .tablet,
              now.isFinite, now >= 0 else { throw RemoteTouchError.invalidPairing }
        pending = secret
        self.source = source
        issuedAt = now
    }
    mutating func consume(secret: Data, now: Double) throws -> SensorSource {
        guard let pending, let source, now.isFinite, now >= issuedAt,
              now-issuedAt < 60 else {
            clear()
            throw RemoteTouchError.invalidPairing
        }
        guard secret.count == 32 else { throw RemoteTouchError.invalidPairing }
        var difference: UInt8 = 0
        for (a,b) in zip(pending,secret) { difference |= a ^ b }
        guard difference == 0 else { throw RemoteTouchError.invalidPairing }
        clear()
        return source
    }
    mutating func clear() { pending = nil; source = nil; issuedAt = 0 }
}

struct RemoteTouchPeer: Sendable {
    let source: SensorSource
    var routerSession: UUID?
    private var lastSeen: Double
    private var lastSequence: UInt64 = 0
    private var windowStart: Double
    private var count = 0
    init(source: SensorSource, now: Double) {
        self.source = source
        lastSeen = now
        windowStart = now
    }
    func expired(now: Double) -> Bool {
        !now.isFinite || now < lastSeen ||
        now-lastSeen >= (routerSession == nil ? 2.0 : 0.35)
    }
    mutating func accept(_ frame: RemoteTouchFrame, now: Double) -> Bool {
        guard !expired(now: now), frame.sequence > lastSequence,
              frame.kind != .heartbeat || routerSession == nil else { return false }
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
