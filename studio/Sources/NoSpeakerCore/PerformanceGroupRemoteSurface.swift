import Foundation

/// Host-selected remote surface families per logical slot. The existing
/// wire schema remains authoritative; the peer never supplies MIDI targets.
public enum PerformanceGroupRemoteSurface: String, CaseIterable, Sendable {
    case xy, drums, piano, pedalboard

    public var signals: Set<SensorSignal> {
        switch self {
        case .xy: return [.x,.y,.contact]
        case .drums: return Set(RemoteDrumPads.signals)
        case .piano: return Set(RemotePiano.signals)
        case .pedalboard: return Set(RemotePedalboard.signals)
        }
    }

    /// Initial mixed-surface candidate: at most two mapped families per
    /// connection. The shared rate budget is not multiplied by family count.
    public static let maximumFamilies = 2

    public static func modes(for routes:[SensorMapping]) -> Set<Self>? {
        guard !routes.isEmpty, routes.allSatisfy({
            $0.source.isGroupRemote &&
            PerformanceGroupGamepadSession.permitsLiveControl($0) &&
            $0.pedalMode == nil
        }) else { return nil }
        var result:Set<Self> = []
        for route in routes {
            guard let family = allCases.first(where:{ $0.signals.contains(route.signal) }) else { return nil }
            switch family {
            case .xy: break
            case .drums: guard RemoteDrumPads.permits(route) else { return nil }
            case .piano: guard RemotePiano.permits(route) else { return nil }
            case .pedalboard: guard RemotePedalboard.permits(route) else { return nil }
            }
            result.insert(family)
        }
        return result.count <= maximumFamilies ? result : nil
    }

    public static func mode(for routes:[SensorMapping]) -> Self? {
        guard let families = modes(for:routes), families.count == 1 else { return nil }
        return families.first
    }

    static func family(for frame:RemoteTouchFrame) -> Self? {
        switch frame.kind {
        case .touch,.release: return .xy
        case .drumPads: return .drums
        case .pianoKeys: return .piano
        case .pedalboard: return .pedalboard
        default: return nil
        }
    }

    /// Full snapshots including explicit all-off. Reject other surface types
    /// and unmapped active buttons instead of silently interpreting them.
    func snapshot(_ frame:RemoteTouchFrame,mapped:Set<SensorSignal>) -> [SensorSignal:Double]? {
        switch (self,frame.kind) {
        case (.xy,.release): return [:]
        case (.xy,.touch):
            guard let x = frame.x, let y = frame.y else { return nil }
            let values:[SensorSignal:Double] = [.x:x,.y:y,.contact:1]
            return values.filter { mapped.contains($0.key) }
        case (.drums,.drumPads):
            return Self.maskSnapshot(frame,signals:RemoteDrumPads.signals,mapped:mapped)
        case (.piano,.pianoKeys):
            return Self.maskSnapshot(frame,signals:RemotePiano.signals,mapped:mapped)
        case (.pedalboard,.pedalboard):
            guard let mask = frame.mask, let levels = frame.levels else { return nil }
            var values:[SensorSignal:Double] = [:]
            for (index,signal) in RemotePedalboard.signals.enumerated() where mask & (1 << index) != 0 {
                guard mapped.contains(signal) else { return nil }
                values[signal] = levels[index]
            }
            return values
        default: return nil
        }
    }

    private static func maskSnapshot(_ frame:RemoteTouchFrame,signals:[SensorSignal],
                                     mapped:Set<SensorSignal>) -> [SensorSignal:Double]? {
        guard let mask = frame.mask else { return nil }
        var result:[SensorSignal:Double] = [:]
        for (index,signal) in signals.enumerated() where mask & (1 << index) != 0 {
            guard mapped.contains(signal) else { return nil }
            result[signal] = 1
        }
        return result
    }
}

/// Per-binding receipt and wire sequence fence. Not a pairing or network API.
/// Caller must first authenticate the connection and supply its host receipt.
struct PerformanceGroupRemoteFence: Sendable {
    private var sequence:UInt64 = 0
    private var lastReceipt:Double?
    private var windowStart:Double?
    private var count = 0

    mutating func accept(_ bytes:Data,receipt:Double,now:Double) -> RemoteTouchFrame? {
        guard receipt.isFinite, now.isFinite, receipt >= 0, receipt <= now,
              now-receipt < 0.1, lastReceipt.map({ receipt >= $0 }) ?? true,
              let frame = try? RemoteTouchFrame.read(bytes), frame.sequence > sequence else { return nil }
        if let start = windowStart, receipt-start >= 1 { windowStart = receipt; count = 0 }
        if windowStart == nil { windowStart = receipt }
        guard count < 90 else { return nil }
        count += 1
        sequence = frame.sequence
        lastReceipt = receipt
        return frame
    }
}
