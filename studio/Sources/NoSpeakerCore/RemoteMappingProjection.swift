import Foundation

/// Read-only, source-scoped destination projection. No route IDs, patch names,
/// calibration, velocities, or local source data are included in destination rows.
/// Labels are a separate projection with independent invitation consent.
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
    let labels: [RemoteMappingLabel]

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
        let mapped = Set(grouped.keys.map(\.signal))
        labels = (patch.performanceLayout?.resolved(for: patch.routes) ?? [])
            .compactMap { widget -> RemoteMappingLabel? in
                guard widget.source == source,
                      let id = Self.signals.firstIndex(of: widget.signal), mapped.contains(id),
                      RemoteMappingLabel.permits(widget.label) else { return nil }
                return RemoteMappingLabel(signal:id,text:widget.label)
            }.sorted { $0.signal < $1.signal }
    }

    func labelPage(_ index: Int, sequence: UInt64, allowed: Bool) throws -> RemoteMappingLabelPage {
        let visible = allowed ? labels : []
        let pages = max(1,visible.count)
        guard (0..<pages).contains(index), visible.count <= 49,
              (1...9_007_199_254_740_991).contains(sequence) else { throw RemoteTouchError.invalidFrame }
        return RemoteMappingLabelPage(sequence:sequence,page:index,pages:pages,total:visible.count,
                                      rows:visible.isEmpty ? [] : [visible[index]])
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


/// A single bounded UTF-8 label, encoded as a fixed tuple of logical ID and
/// canonical unpadded base64url. No label is interpreted as code or MIDI.
struct RemoteMappingLabel: Encodable, Equatable, Sendable {
    let signal: Int
    let text: String

    static func permits(_ text: String) -> Bool {
        guard (1...64).contains(text.utf8.count),
              text.unicodeScalars.contains(where: { !$0.properties.isWhitespace }) else { return false }
        return text.unicodeScalars.allSatisfy {
            $0.properties.generalCategory != .control && $0.properties.generalCategory != .format
        }
    }

    func encode(to encoder: Encoder) throws {
        guard (0...48).contains(signal), Self.permits(text) else { throw RemoteTouchError.invalidFrame }
        let value = Data(text.utf8).base64EncodedString()
            .replacingOccurrences(of:"+",with:"-")
            .replacingOccurrences(of:"/",with:"_")
            .replacingOccurrences(of:"=",with:"")
        var tuple = encoder.unkeyedContainer()
        try tuple.encode(signal)
        try tuple.encode(value)
    }
}

/// Bounded host-generated label response.
public struct RemoteMappingLabelPage: Encodable, Equatable, Sendable {
    let kind = "mappingLabels"
    let version = 8
    let sequence: UInt64
    let page: Int
    let pages: Int
    let total: Int
    let rows: [RemoteMappingLabel]
    public func encoded() throws -> Data {
        let data = try JSONEncoder().encode(self)
        guard data.count <= RemoteTouchFrame.maximumBytes else { throw RemoteTouchError.invalidFrame }
        return data
    }
}
