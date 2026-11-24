import Foundation

/// One explicitly selected physical surface per source kind. A primary
/// contact drives the patch, not a synthetic pressure or finger-count sensor.
public struct PhysicalPatchRuntime: Sendable {
    public static let supportedSignals: Set<SensorSignal> = [.x, .y, .contact, .contactSize]
    public static let timeout = 0.35
    private var router = SensorRouter()
    private var supported: Set<SensorSource> = []
    private var sessions: [SensorSource: UUID] = [:]
    private var seen: [SensorSource: Double] = [:]
    private var sequence: UInt64 = 0
    private var motionSources: Set<SensorSource> = []
    private var remoteEnabled = false
    private var pairing = RemotePairingGate()
    private var remotePeers: [UUID: RemoteTouchPeer] = [:]
    public static let maximumRemotePeers = 4
    public var remotePeerIDs: Set<UUID> { Set(remotePeers.keys) }

    public init() {}
    public var activeSources: Set<SensorSource> { Set(sessions.keys) }

    public static func supports(_ patch: InstrumentPatch, allowRemote: Bool = false) -> Bool {
        patch.isValid && !patch.routes.isEmpty && patch.routes.allSatisfy {
            switch $0.source {
            case .trackpad, .magicMouse: return supportedSignals.contains($0.signal)
            case .lid: return $0.signal == .angle
            case .touchBar: return $0.signal == .x
            case .camera: return [.x,.y,.gesture,.contact].contains($0.signal)
            case .phone, .tablet:
                guard allowRemote else { return false }
                if [.x,.y,.contact].contains($0.signal) { return true }
                return [.tiltYaw,.tiltPitch,.tiltRoll].contains($0.signal) &&
                    ($0.destination.kind == .controlChange || $0.destination.kind == .pitchBend)
            default: return false
            }
        }
    }

    public mutating func configure(_ patch: InstrumentPatch, allowRemote: Bool = false) throws {
        guard sessions.isEmpty, remotePeers.isEmpty, Self.supports(patch, allowRemote: allowRemote) else { throw SensorRouterError.invalidMappings }
        try router.configure(patch.routes)
        supported = Set(patch.routes.map(\.source))
        motionSources = Set(patch.routes.filter { [.tiltYaw,.tiltPitch,.tiltRoll].contains($0.signal) }.map(\.source))
        remoteEnabled = allowRemote
        pairing.clear()
        seen = [:]
        sequence = 0
    }

    /// hostTime is local receipt time, not the undocumented driver timestamp.
    /// An empty frame or invalid sample releases the entire physical source.
    public mutating func receive(source: SensorSource, x: Double?, y: Double?, size: Double?,
                                 hostTime: Double, now: Double) -> [SensorCommand] {
        guard (source == .trackpad || source == .magicMouse), supported.contains(source), hostTime.isFinite, now.isFinite,
              hostTime >= 0, hostTime <= now, now - hostTime < Self.timeout,
              hostTime >= (seen[source] ?? 0) else { return [] }
        seen[source] = hostTime
        guard let x, let y, let size, [x,y,size].allSatisfy({ $0.isFinite && (0...1).contains($0) })
        else { return disconnect(source) }
        if sessions[source] == nil {
            sessions[source] = try? router.connect(source, now: hostTime)
        }
        guard let session = sessions[source] else { return [] }
        var result: [SensorCommand] = []
        // Position/control updates precede contact-gated Note On.
        for (signal, value): (SensorSignal, Double) in [(.x,x),(.y,y),(.contactSize,size),(.contact,1)] {
            sequence &+= 1
            result += router.ingest(.init(session: session, signal: signal, value: value,
                                          sequence: sequence, timestamp: hostTime), now: hostTime)
        }
        return result
    }

    /// Lid degrees are normalized over the documented valid sensor range.
    /// Mapping calibration then selects the comfortable musical sweep.
    public static func normalizedLid(_ degrees: Double) -> Double? {
        guard degrees.isFinite, (5...175).contains(degrees) else { return nil }
        return (degrees - 5) / 170
    }

    /// Scalar adapters share the same router and ownership as touch surfaces.
    /// Nil is a release/lost sample, not a synthetic input of zero.
    public mutating func receiveScalar(source: SensorSource, value: Double?,
                                       hostTime: Double, now: Double) -> [SensorCommand] {
        guard source == .lid || source == .touchBar, supported.contains(source),
              hostTime.isFinite, now.isFinite, hostTime >= 0, hostTime <= now,
              now - hostTime < Self.timeout, hostTime >= (seen[source] ?? 0) else { return [] }
        seen[source] = hostTime
        guard let value, value.isFinite, (0...1).contains(value) else { return disconnect(source) }
        if sessions[source] == nil { sessions[source] = try? router.connect(source, now: hostTime) }
        guard let session = sessions[source] else { return [] }
        sequence &+= 1
        return router.ingest(.init(session: session, signal: source == .lid ? .angle : .x,
                                   value: value, sequence: sequence, timestamp: hostTime), now: hostTime)
    }

    /// Camera frame identity is not tracked across hands. The adapter
    /// rejects multiple/low-confidence hands; nil releases this source.
    public mutating func receiveHand(_ hand: AirHandSample?, hostTime: Double, now: Double) -> [SensorCommand] {
        let source = SensorSource.camera
        guard supported.contains(source), hostTime.isFinite, now.isFinite,
              hostTime >= 0, hostTime <= now, now - hostTime < Self.timeout,
              hostTime >= (seen[source] ?? 0) else { return [] }
        seen[source] = hostTime
        guard let hand else { return disconnect(source) }
        if sessions[source] == nil { sessions[source] = try? router.connect(source, now: hostTime) }
        guard let session = sessions[source] else { return [] }
        var result: [SensorCommand] = []
        for (signal, value): (SensorSignal, Double) in [(.x,hand.x),(.y,hand.y),(.gesture,hand.aperture),(.contact,1)] {
            sequence &+= 1
            result += router.ingest(.init(session: session, signal: signal, value: value,
                                          sequence: sequence, timestamp: hostTime), now: hostTime)
        }
        return result
    }

    /// Host-only API: a future transport must bind returned IDs to connections.
    public mutating func issueRemotePairing(secret: Data, source: SensorSource, now: Double) throws {
        guard remoteEnabled, supported.contains(source), source == .phone || source == .tablet
        else { throw RemoteTouchError.unavailable }
        try pairing.issue(secret: secret, source: source, now: now)
    }

    public mutating func admitRemote(secret: Data, now: Double) throws -> UUID {
        guard remoteEnabled else { throw RemoteTouchError.unavailable }
        guard remotePeers.count < Self.maximumRemotePeers else { throw RemoteTouchError.capacity }
        let source = try pairing.consume(secret: secret, now: now)
        guard supported.contains(source) else { throw RemoteTouchError.unavailable }
        let id = UUID()
        remotePeers[id] = RemoteTouchPeer(source: source, now: now)
        return id
    }

    public mutating func receiveRemote(_ id: UUID, bytes: Data, now: Double) -> RemoteTouchResult {
        guard var peer = remotePeers[id], remoteEnabled else { return .close([]) }
        guard let frame = try? RemoteTouchFrame.read(bytes), peer.accept(frame, now: now)
        else { return .close(revokeRemote(id)) }
        switch frame.kind {
        case .heartbeat:
            remotePeers[id] = peer
            return .accepted([])
        case .release:
            let commands = peer.routerSession.map { router.disconnect($0) } ?? []
            peer.routerSession = nil
            peer.lastTouch = nil
            remotePeers[id] = peer
            return .accepted(commands)
        case .touch:
            if peer.routerSession == nil { peer.routerSession = try? router.connect(peer.source, now: now) }
            guard let session = peer.routerSession, let x = frame.x, let y = frame.y
            else { return .close(revokeRemote(id)) }
            peer.lastTouch = now
            remotePeers[id] = peer
            var commands: [SensorCommand] = []
            for (signal, value): (SensorSignal, Double) in [(.x,x),(.y,y),(.contact,1)] {
                sequence &+= 1
                commands += router.ingest(.init(session: session, signal: signal, value: value,
                                                sequence: sequence, timestamp: now), now: now)
            }
            return .accepted(commands)
        case .orientationArm:
            guard motionSources.contains(peer.source),
                  peer.tilt == nil, let angles = frame.angles,
                  let calibration = RemoteTiltCalibration(neutral: angles),
                  peer.motionFreshness.arm(receipt: now, now: now)
            else { return .close(revokeRemote(id)) }
            peer.tilt = calibration
            peer.lastOrientation = now
            remotePeers[id] = peer
            return .accepted([])
        case .orientation:
            guard let tilt = peer.tilt, let angles = frame.angles,
                  peer.motionFreshness.accept(receipt: now, now: now)
            else { return .close(revokeRemote(id)) }
            if peer.motionSession == nil { peer.motionSession = try? router.connect(peer.source, now: now) }
            guard let session = peer.motionSession else { return .close(revokeRemote(id)) }
            peer.lastOrientation = now
            remotePeers[id] = peer
            let values = tilt.normalize(angles)
            var commands: [SensorCommand] = []
            for (signal, value): (SensorSignal, Double) in [(.tiltYaw, values.yaw), (.tiltPitch, values.pitch), (.tiltRoll, values.roll)] {
                sequence &+= 1
                commands += router.ingest(.init(session: session, signal: signal, value: value,
                                                sequence: sequence, timestamp: now), now: now)
            }
            return .accepted(commands)
        case .motionRelease:
            guard peer.tilt != nil else { return .close(revokeRemote(id)) }
            let commands = peer.motionSession.map { router.disconnect($0) } ?? []
            peer.motionSession = nil
            peer.tilt = nil
            peer.lastOrientation = nil
            peer.motionFreshness.disarm()
            remotePeers[id] = peer
            return .accepted(commands)
        }
    }

    public mutating func revokeRemote(_ id: UUID) -> [SensorCommand] {
        guard let peer = remotePeers.removeValue(forKey: id) else { return [] }
        return [peer.routerSession, peer.motionSession].compactMap { $0 }.flatMap { router.disconnect($0) }
    }

    public mutating func cancelRemotePairing() { pairing.clear() }

    /// Stop remote admission and release remote owners without disturbing local inputs.
    public mutating func disableRemote() -> [SensorCommand] {
        remoteEnabled = false
        pairing.clear()
        let ids = remotePeers.keys.sorted { $0.uuidString < $1.uuidString }
        return ids.flatMap { revokeRemote($0) }
    }

    public mutating func expire(now: Double) -> [SensorCommand] {
        guard now.isFinite else { return [] }
        let stale = sessions.keys.filter { now - (seen[$0] ?? 0) >= Self.timeout }
            .sorted { $0.rawValue < $1.rawValue }
        var commands = stale.flatMap { disconnect($0) }
        let expiredPeers = remotePeers.filter { $0.value.expired(now: now) }.map(\.key)
            .sorted { $0.uuidString < $1.uuidString }
        for id in expiredPeers { commands += revokeRemote(id) }
        return commands
    }

    private mutating func disconnect(_ source: SensorSource) -> [SensorCommand] {
        guard let id = sessions.removeValue(forKey: source) else { return [] }
        return router.disconnect(id)
    }

    public mutating func stop() -> [SensorCommand] {
        sessions = [:]
        seen = [:]
        supported = []
        motionSources = []
        remoteEnabled = false
        pairing.clear()
        remotePeers = [:]
        return router.panic()
    }
}
