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
        let notes = parts.compactMap { Int($0) }
        guard notes.count == parts.count, notes.allSatisfy({ (0...127).contains($0) }),
              Set(notes).count == notes.count else { return nil }
        return notes
    }

    /// Replacement is scoped to the selected physical control. Other slot
    /// routes, including calibration and custom responses, remain untouched.
    public static func replace(in patch: InstrumentPatch, source: SensorSource, signal: SensorSignal,
                               destinations: [SensorDestination], velocity: Int = 100) throws -> InstrumentPatch {
        guard patch.isValid, GamepadFrame.sources.contains(source), GamepadFrame.signals.contains(signal),
              destinations.count <= 12, Set(destinations).count == destinations.count,
              (1...127).contains(velocity) else { throw SensorRouterError.invalidMappings }
        var next = patch
        next.routes.removeAll { $0.source == source && $0.signal == signal }
        guard destinations.count <= SensorRouter.maxMappings - next.routes.count else {
            throw SensorRouterError.invalidMappings
        }
        next.routes += destinations.map {
            SensorMapping(id:UUID().uuidString,source:source,signal:signal,destination:$0,velocity:velocity)
        }
        guard next.isValid else { throw SensorRouterError.invalidMappings }
        return next
    }
}
