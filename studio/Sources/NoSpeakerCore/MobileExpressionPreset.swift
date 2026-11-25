import Foundation

/// Equal-tempered, discrete note zones over the existing remote piano mask.
public enum MobileExpressionPreset: String, CaseIterable, Identifiable, Sendable {
    case chromatic, major, minor, pentatonic, custom
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .chromatic: "Chromatic"
        case .major: "Major"
        case .minor: "Natural minor"
        case .pentatonic: "Major pentatonic"
        case .custom: "Custom notes"
        }
    }
    public func notes(root: Int, custom: String = "") -> [Int]? {
        if self == .custom {
            guard custom.utf8.count <= 256 else { return nil }
            let tokens = custom.split(whereSeparator: { $0 == "," || $0.isWhitespace })
            guard (1...25).contains(tokens.count) else { return nil }
            let values = tokens.compactMap { Int($0) }
            guard values.count == tokens.count, values.allSatisfy({ (0...127).contains($0) }) else { return nil }
            return values
        }
        guard (0...127).contains(root) else { return nil }
        let degrees: [Int]
        switch self {
        case .chromatic: degrees = Array(0..<12)
        case .major: degrees = [0,2,4,5,7,9,11]
        case .minor: degrees = [0,2,3,5,7,8,10]
        case .pentatonic: degrees = [0,2,4,7,9]
        case .custom: return nil
        }
        // One octave inclusive, with no silent clipping at MIDI boundaries.
        let values = (degrees + [12]).map { root + $0 }
        return values.allSatisfy({ $0 <= 127 }) ? values : nil
    }

    public func appending(to patch: InstrumentPatch, source: SensorSource,
                          channel: Int, root: Int, custom: String = "") throws -> InstrumentPatch {
        guard patch.isValid, (source == .phone || source == .tablet),
              (0...15).contains(channel), let values = notes(root: root, custom: custom),
              !patch.routes.contains(where: { $0.source == source && RemotePiano.signals.contains($0.signal) }),
              values.count + 1 <= SensorRouter.maxMappings - patch.routes.count else {
            throw SensorRouterError.invalidMappings
        }
        var next = patch
        next.routes += zip(RemotePiano.keySignals, values).map { signal, note in
            SensorMapping(id: UUID().uuidString, source: source, signal: signal,
                          destination: .init(.note, channel: channel, number: note))
        }
        next.routes.append(.init(id: UUID().uuidString, source: source, signal: .pianoSustain,
                                 destination: .init(.sustain, channel: channel)))
        guard next.isValid else { throw SensorRouterError.invalidMappings }
        return next
    }
}
