/// Optional persisted mapping mode. Nil retains the original continuous
/// controller or momentary note/sustain behavior.
public enum GamepadPedalMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case hold = "Hold"
    case toggle = "Toggle"
    public var id: String { rawValue }

    public static func permits(_ route: SensorMapping) -> Bool {
        guard route.pedalMode != nil else { return true }
        return GamepadFrame.sources.contains(route.source) &&
            (GamepadFrame.buttons.contains(route.signal) || GamepadFrame.triggers.contains(route.signal)) &&
            route.calibration == SensorCalibration() && route.response == nil &&
            (route.destination.kind == .sustain ||
                (route.destination.kind == .controlChange &&
                 ![0,6,7,11,32,38,96,97,98,99,100,101].contains(route.destination.number)))
    }

    /// Binary CC ownership is OR-reconciled, not mixed with analog curves.
    /// Reject ambiguous configurations rather than reinterpret old mappings.
    public static func switchTargets(_ routes: [SensorMapping]) -> Set<SensorDestination>? {
        guard routes.allSatisfy(permits) else { return nil }
        let targets = Set(routes.filter { $0.pedalMode != nil && $0.destination.kind == .controlChange }.map(\.destination))
        guard routes.allSatisfy({ !targets.contains($0.destination) || $0.pedalMode != nil }) else { return nil }
        return targets
    }
}
