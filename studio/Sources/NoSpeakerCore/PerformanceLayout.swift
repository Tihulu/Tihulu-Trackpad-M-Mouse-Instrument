import Foundation

public enum PerformanceControlKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case slider, pedal, pad, xy, knob, ribbon, key
    public var id: String { rawValue }
}

/// Data-only layout; each widget addresses one existing source/signal
/// or the two axes of the same source. It never creates a MIDI mapping.
public struct PerformanceWidget: Codable, Equatable, Identifiable, Sendable {
    public var id: String { source.rawValue + ":" + signal.rawValue }
    public var source: SensorSource
    public var signal: SensorSignal
    public var kind: PerformanceControlKind
    public var label: String
    public var wide: Bool
    public init(source: SensorSource, signal: SensorSignal, kind: PerformanceControlKind = .slider,
                label: String = "", wide: Bool = false) {
        self.source = source; self.signal = signal; self.kind = kind
        self.label = label; self.wide = wide
    }
    public var title: String { label.isEmpty ? id : label }
    public var inputs: [PatchSimulation.Input] {
        let first = PatchSimulation.Input(source: source, signal: signal)
        return kind == .xy ? [first, .init(source: source, signal: .y)] : [first]
    }
    /// A held key is only offered when every mapped target is a note
    /// and a single endpoint of the input can activate every note gate.
    /// This also supports inverted gates without synthetic zero releases.
    public func keyPressValue(for routes: [SensorMapping]) -> Double? {
        let matches = routes.filter { $0.source == source && $0.signal == signal }
        guard !matches.isEmpty, matches.allSatisfy({ $0.destination.kind == .note && $0.isValid }) else { return nil }
        return [1.0, 0.0].first { value in
            matches.allSatisfy { ($0.calibration.apply(value) ?? -1) >= $0.threshold }
        }
    }

    public var isValid: Bool {
        label.utf8.count <= 64 &&
        !label.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) } &&
        (kind != .xy || signal == .x)
    }
}

public struct PerformanceLayout: Codable, Equatable, Sendable {
    public var widgets: [PerformanceWidget]
    public init(widgets: [PerformanceWidget] = []) { self.widgets = widgets }
    public var isValid: Bool {
        guard widgets.count <= SensorRouter.maxMappings, widgets.allSatisfy(\.isValid) else { return false }
        let keys = widgets.flatMap(\.inputs)
        return keys.count == Set(keys).count
    }

    /// Retain saved labels/order for assigned controls; unmapped widgets
    /// are dormant, and newly mapped signals get a default slider.
    public func resolved(for routes: [SensorMapping]) -> [PerformanceWidget] {
        guard isValid else { return [] }
        let available = Set(routes.map { PatchSimulation.Input(source: $0.source, signal: $0.signal) })
        var result = widgets.filter { $0.inputs.allSatisfy { available.contains($0) } }.map { widget in
            var copy = widget
            if copy.kind == .key && copy.keyPressValue(for: routes) == nil { copy.kind = .slider }
            return copy
        }
        let covered = Set(result.flatMap(\.inputs))
        for input in available.subtracting(covered).sorted(by: { $0.id < $1.id }) {
            result.append(.init(source: input.source, signal: input.signal))
        }
        return result
    }

    public static func defaults(for routes: [SensorMapping]) -> Self {
        .init(widgets: Self().resolved(for: routes))
    }
}
