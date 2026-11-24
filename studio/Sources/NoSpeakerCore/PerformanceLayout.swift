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
        var result = widgets.compactMap { widget -> PerformanceWidget? in
            var copy = widget
            if !widget.inputs.allSatisfy({ available.contains($0) }) {
                // A temporarily missing Y axis must not erase the user's X label.
                guard widget.kind == .xy, available.contains(widget.inputs[0]) else { return nil }
                copy.kind = .slider
            }
            if copy.kind == .key && copy.keyPressValue(for: routes) == nil { copy.kind = .slider }
            return copy
        }
        let covered = Set(result.flatMap(\.inputs))
        for input in available.subtracting(covered).sorted(by: { $0.id < $1.id }) {
            result.append(.init(source: input.source, signal: input.signal))
        }
        return result
    }

    /// Save edits to the visible layout without dropping dormant custom controls.
    /// If a temporary XY/key fallback is unchanged, retain its original style.
    /// An explicit edit of that fallback replaces it. Reset can opt out of retention.
    public func applyingVisibleEdits(_ edited: [PerformanceWidget], for routes: [SensorMapping],
                                     preserveDormant: Bool = true) throws -> Self {
        let candidate = Self(widgets:edited)
        guard isValid, candidate.isValid else { throw SensorRouterError.invalidMappings }
        let available = Set(routes.map { PatchSimulation.Input(source:$0.source,signal:$0.signal) })
        guard edited.allSatisfy({ $0.inputs.allSatisfy { available.contains($0) } }) else {
            throw SensorRouterError.invalidMappings
        }
        guard preserveDormant else { return candidate }
        let baseline = resolved(for:routes)
        var result = edited
        for saved in widgets {
            let inputs = Set(saved.inputs)
            let overlaps = result.indices.filter { !inputs.isDisjoint(with:result[$0].inputs) }
            let fullyMapped = inputs.isSubset(of:available)
            if fullyMapped && !(saved.kind == .key && saved.keyPressValue(for:routes) == nil) { continue }
            if overlaps.isEmpty {
                // Only genuinely dormant controls may be restored without overlap.
                if inputs.isDisjoint(with:available) { result.append(saved) }
            } else if overlaps.count == 1, let index = overlaps.first,
                      let before = baseline.first(where: { !inputs.isDisjoint(with:$0.inputs) }),
                      before == result[index] {
                result[index] = saved
            }
        }
        let merged = Self(widgets:result)
        guard merged.isValid else { throw SensorRouterError.invalidMappings }
        return merged
    }

    public static func defaults(for routes: [SensorMapping]) -> Self {
        .init(widgets: Self().resolved(for: routes))
    }
}
