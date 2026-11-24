import Foundation

/// Read-only, source-scoped destination projection. No route IDs, patch names,
/// calibration, velocities, labels, or local source data are included.
struct RemoteMappingProjection: Sendable {
    static let signals: [SensorSignal] = [.x,.y,.contact,.tiltYaw,.tiltPitch,.tiltRoll,
        .accelerationMagnitude,.rotationMagnitude,.airStrike] +
        RemoteDrumPads.signals + RemotePiano.signals + RemotePedalboard.signals
    private struct Target: Hashable, Sendable {
        let signal: Int
        let kind: Int
        let channel: Int
        let number: Int
        var columns: [Int] { [signal,kind,channel,number] }
    }
    let rows: [[Int]]

    init(patch: InstrumentPatch, source: SensorSource) throws {
        guard source == .phone || source == .tablet,
              PhysicalPatchRuntime.supports(patch, allowRemote: true),
              Self.signals.count == 49 else { throw RemoteTouchError.invalidFrame }
        var grouped: [Target:Int] = [:]
        for route in patch.routes where route.source == source {
            guard let signal = Self.signals.firstIndex(of: route.signal) else { throw RemoteTouchError.invalidFrame }
            let kind: Int
            switch route.destination.kind {
            case .note: kind = 0
            case .controlChange: kind = 1
            case .pitchBend: kind = 2
            case .sustain: kind = 3
            }
            let key = Target(signal:signal,kind:kind,channel:route.destination.channel,number:route.destination.number)
            grouped[key,default:0] += 1
        }
        rows = grouped.keys.sorted { $0.columns.lexicographicallyPrecedes($1.columns) }
            .map { $0.columns + [grouped[$0]!] }
    }

    func page(_ index: Int, sequence: UInt64, detail: Bool) throws -> RemoteMappingPage {
        let visible = detail ? rows : []
        let pages = max(1,(visible.count+7)/8)
        guard (0..<pages).contains(index), (1...9_007_199_254_740_991).contains(sequence),
              visible.count <= 64 else { throw RemoteTouchError.invalidFrame }
        let start = index*8
        return RemoteMappingPage(sequence:sequence,page:index,pages:pages,total:visible.count,detail:detail,
                                 rows:Array(visible[start..<min(start+8,visible.count)]))
    }
}

/// Host-generated bounded read-only v8 response.
public struct RemoteMappingPage: Encodable, Equatable, Sendable {
    let kind = "mapping"
    let version = 8
    let sequence: UInt64
    let page: Int
    let pages: Int
    let total: Int
    let detail: Bool
    let rows: [[Int]]
    public func encoded() throws -> Data {
        let data = try JSONEncoder().encode(self)
        guard data.count <= RemoteTouchFrame.maximumBytes else { throw RemoteTouchError.invalidFrame }
        return data
    }
}
