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

    public init() {}
    public var activeSources: Set<SensorSource> { Set(sessions.keys) }

    public static func supports(_ patch: InstrumentPatch) -> Bool {
        patch.isValid && !patch.routes.isEmpty && patch.routes.allSatisfy {
            switch $0.source {
            case .trackpad, .magicMouse: return supportedSignals.contains($0.signal)
            case .lid: return $0.signal == .angle
            case .touchBar: return $0.signal == .x
            case .camera: return [.x,.y,.gesture,.contact].contains($0.signal)
            default: return false
            }
        }
    }

    public mutating func configure(_ patch: InstrumentPatch) throws {
        guard sessions.isEmpty, Self.supports(patch) else { throw SensorRouterError.invalidMappings }
        try router.configure(patch.routes)
        supported = Set(patch.routes.map(\.source))
        seen = [:]
        sequence = 0
    }

    /// hostTime is local receipt time, not the undocumented driver timestamp.
    /// An empty frame or invalid sample releases the entire physical source.
    public mutating func receive(source: SensorSource, x: Double?, y: Double?, size: Double?,
                                 hostTime: Double, now: Double) -> [SensorCommand] {
        guard supported.contains(source), hostTime.isFinite, now.isFinite,
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

    public mutating func expire(now: Double) -> [SensorCommand] {
        guard now.isFinite else { return [] }
        let stale = sessions.keys.filter { now - (seen[$0] ?? 0) >= Self.timeout }
            .sorted { $0.rawValue < $1.rawValue }
        return stale.flatMap { disconnect($0) }
    }

    private mutating func disconnect(_ source: SensorSource) -> [SensorCommand] {
        guard let id = sessions.removeValue(forKey: source) else { return [] }
        return router.disconnect(id)
    }

    public mutating func stop() -> [SensorCommand] {
        sessions = [:]
        seen = [:]
        supported = []
        return router.panic()
    }
}
