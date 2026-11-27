/// Candidate first-manual-mode configuration. Construct both halves from a
/// single immutable snapshot; the generic output plan stays axis-agnostic.
/// This validates shape and wire width, not runtime ownership or delivery.
public struct NativeHelperRelativeManualPreflight: Sendable {
    public typealias Axis = NativeHelperRelativeClutch.Axis
    public let lanes: [Axis: NativeHelperRelativeClutch.Lane]
    public let plan: NativeHelperRelativeOutputPlan

    public init?(settings: NativeHelperRelativeManualSettings, enabled: Set<Axis>,
                 targets: [Axis: SensorDestination]) {
        guard enabled == Set(targets.keys),
              let lanes = settings.lanes(enabled: enabled),
              let plan = NativeHelperRelativeOutputPlan(targets: targets) else { return nil }
        for (axis, target) in targets {
            switch axis {
            case .x: guard target.kind == .pitchBend, lanes[axis]?.upper == 16383 else { return nil }
            case .y, .contactSize: guard target.kind == .controlChange, lanes[axis]?.upper == 127 else { return nil }
            }
        }
        self.lanes = lanes
        self.plan = plan
    }
}
/// First manual native Helper uses the existing single MIDI channel.
/// Build destinations from one immutable, strictly validated selection.
/// Construction is not arm; source, lease, cleanup and transport checks remain mandatory.
public struct NativeHelperRelativeSingleChannel: Sendable {
    public typealias Axis = NativeHelperRelativeClutch.Axis
    public let channel: Int
    public let configuration: NativeHelperRelativeManualPreflight

    public init?(settings: NativeHelperRelativeManualSettings, enabled: Set<Axis>,
                 channel: Int, vibratoCC: Int, expressionCC: Int) {
        guard (0...15).contains(channel) else { return nil }
        var targets: [Axis: SensorDestination] = [:]
        for axis in enabled {
            switch axis {
            case .x: targets[axis] = .init(.pitchBend, channel: channel)
            case .y: targets[axis] = .init(.controlChange, channel: channel, number: vibratoCC)
            case .contactSize: targets[axis] = .init(.controlChange, channel: channel, number: expressionCC)
            }
        }
        guard let configuration = NativeHelperRelativeManualPreflight(settings: settings, enabled: enabled,
                                                                    targets: targets) else { return nil }
        self.channel = channel
        self.configuration = configuration
    }
}
