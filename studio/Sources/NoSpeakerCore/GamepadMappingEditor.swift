import Foundation

public enum GamepadMappingEditor {
    public static func label(_ signal: SensorSignal) -> String {
        switch signal {
        case .padA: "A"
        case .padB: "B"
        case .padX: "X"
        case .padY: "Y"
        case .padLB: "LB"
        case .padRB: "RB"
        case .padLT: "LT"
        case .padRT: "RT"
        case .padUp: "D-pad ↑"
        case .padDown: "D-pad ↓"
        case .padLeft: "D-pad ←"
        case .padRight: "D-pad →"
        case .padLSX: "Left stick X"
        case .padLSY: "Left stick Y"
        case .padRSX: "Right stick X"
        case .padRSY: "Right stick Y"
        case .padLClick: "Left stick click"
        case .padRClick: "Right stick click"
        default: signal.rawValue
        }
    }

    public static func parseNotes(_ text: String) -> [Int]? {
        guard text.utf8.count <= 128 else { return nil }
        let parts = text.split(whereSeparator: { $0 == "," || $0.isWhitespace })
        guard (1...12).contains(parts.count) else { return nil }
        let notes = parts.compactMap { parseNote(String($0)) }
        guard notes.count == parts.count, notes.allSatisfy({ (0...127).contains($0) }),
              Set(notes).count == notes.count else { return nil }
        return notes
    }

    private static func parseNote(_ token: String) -> Int? {
        if let midi = Int(token) { return (0...127).contains(midi) ? midi : nil }
        let name = token.uppercased().replacingOccurrences(of:"♯",with:"#").replacingOccurrences(of:"♭",with:"B")
        guard let first = name.first, "ABCDEFG".contains(first) else { return nil }
        var rest = name.dropFirst()
        let base = ["C":0,"D":2,"E":4,"F":5,"G":7,"A":9,"B":11]
        guard var pitch = base[String(first)] else { return nil }
        if rest.first == "#" { pitch += 1; rest = rest.dropFirst() }
        else if rest.first == "B" { pitch -= 1; rest = rest.dropFirst() }
        guard let octave = Int(rest), (-1...9).contains(octave) else { return nil }
        let midi = (octave+1)*12+pitch
        return (0...127).contains(midi) ? midi : nil
    }

    /// Replacement is scoped to the selected physical control. Other slot
    /// routes, including calibration and custom responses, remain untouched.
    public static func replace(in patch: InstrumentPatch, source: SensorSource, signal: SensorSignal,
                               destinations: [SensorDestination], velocity: Int = 100,
                               pedalMode: GamepadPedalMode? = nil) throws -> InstrumentPatch {
        guard patch.isValid, GamepadFrame.sources.contains(source), GamepadFrame.signals.contains(signal),
              destinations.count <= 12, Set(destinations).count == destinations.count,
              (1...127).contains(velocity) else { throw SensorRouterError.invalidMappings }
        var next = patch
        let previous = next.routes.filter { $0.source == source && $0.signal == signal }
        next.routes.removeAll { $0.source == source && $0.signal == signal }
        guard destinations.count <= SensorRouter.maxMappings - next.routes.count else {
            throw SensorRouterError.invalidMappings
        }
        next.routes += destinations.map { target in
            let matches = previous.filter { $0.destination == target }
            if matches.count == 1, var existing = matches.first {
                if target.kind == .note { existing.velocity = velocity }
                existing.pedalMode = pedalMode
                if pedalMode != nil { existing.calibration = .init(); existing.response = nil }
                return existing
            }
            return SensorMapping(id:UUID().uuidString,source:source,signal:signal,destination:target,velocity:velocity,pedalMode:pedalMode)
        }
        guard next.isValid else { throw SensorRouterError.invalidMappings }
        return next
    }

    /// Copy a complete map without mutating the original controller. A
    /// populated destination requires explicit replacement authorization.
    public static func copy(in patch: InstrumentPatch, from source: SensorSource,
                            to target: SensorSource, channel: Int? = nil,
                            replaceExisting: Bool = false) throws -> InstrumentPatch {
        guard patch.isValid, source != target,
              GamepadFrame.sources.contains(source), GamepadFrame.sources.contains(target),
              channel.map({ (0...15).contains($0) }) ?? true else { throw SensorRouterError.invalidMappings }
        let routes = patch.routes.filter { $0.source == source }
        guard !routes.isEmpty,
              replaceExisting || !patch.routes.contains(where:{ $0.source == target }) else {
            throw SensorRouterError.invalidMappings
        }
        var next = patch
        next.routes.removeAll { $0.source == target }
        guard routes.count <= SensorRouter.maxMappings-next.routes.count else { throw SensorRouterError.invalidMappings }
        next.routes += routes.map { route in
            var cloned = route
            cloned.id = UUID().uuidString
            cloned.source = target
            if let channel { cloned.destination.channel = channel }
            return cloned
        }
        guard next.isValid else { throw SensorRouterError.invalidMappings }
        return next
    }
}
