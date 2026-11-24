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
            ($0.source == .trackpad || $0.source == .magicMouse) && supportedSignals.contains($0.signal)
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
