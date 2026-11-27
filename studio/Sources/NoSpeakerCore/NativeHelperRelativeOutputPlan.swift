/// Pure output planning for a clutched native helper. No wire calls, endpoint
/// ownership, DAW feedback, or atomic admission are implied by this snapshot.
/// The serialized host must recheck ownership and freshness at each actual
/// send, retire the clutch on conflict, and retain failed cleanup debt.
public struct NativeHelperRelativeOutputPlan: Sendable {
    public typealias Axis = NativeHelperRelativeClutch.Axis
    private let targets: [Axis: SensorDestination]
    let targetSet: Set<SensorDestination>
    public var targetDestinations: Set<SensorDestination> { targetSet }

    public init?(targets: [Axis: SensorDestination]) {
        let unique = Set(targets.values)
        guard !targets.isEmpty, unique.count == targets.count,
              unique.allSatisfy({ ContinuousResponse.permitsRelative($0) &&
                  ($0.kind != .controlChange || HelperCCPolicy.permits($0.number)) }) else { return nil }
        self.targets = targets; targetSet = unique
    }

    private func exclusive(owners: LegacyContinuousOwners, reservedChannels: Set<Int>) -> Bool {
        guard targetSet.allSatisfy({ !reservedChannels.contains($0.channel) }) else { return false }
        // Include hidden lower-priority owners; they may become effective
        // on release, so checking only the current winner is insufficient.
        return [LegacyContinuousOwners.Owner.touch, .legacyTouch, .touchBar].allSatisfy {
            targetSet.isDisjoint(with: owners.values(for: $0).keys)
        }
    }

    /// An anchor must not claim a lane or send its reference. A previous
    /// helper owner must have been released before a new anchor is admitted.
    public func permitsAnchor(owners: LegacyContinuousOwners, reservedChannels: Set<Int>) -> Bool {
        owners.values(for: .helper).isEmpty && exclusive(owners: owners, reservedChannels: reservedChannels)
    }

    private func value(_ wire: Int, target: SensorDestination) -> LegacyContinuousOwners.Value? {
        switch target.kind {
        case .pitchBend:
            guard (0...16383).contains(wire) else { return nil }
            return .init(wire, neutral: 8192) // Never configure RPN here.
        case .controlChange:
            guard (0...127).contains(wire) else { return nil }
            return HelperPerformancePolicy.gainValue(wire, cc: target.number)
        default: return nil
        }
    }

    /// Sparse movement updates must retain unchanged owned lanes. An empty
    /// result is not a release; the host handles releaseRequired separately.
    /// Return nil for an invalid or conflicted snapshot, not a neutral write.
    public func prepare(movement: [Axis: Int], owners: LegacyContinuousOwners,
                        reservedChannels: Set<Int>) -> [SensorDestination: LegacyContinuousOwners.Value]? {
        guard exclusive(owners: owners, reservedChannels: reservedChannels) else { return nil }
        var next = owners.values(for: .helper)
        guard next.allSatisfy({ targetSet.contains($0.key) && value($0.value.value, target: $0.key) == $0.value }) else { return nil }
        for (axis, wire) in movement {
            guard let target = targets[axis], let planned = value(wire, target: target) else { return nil }
            next[target] = planned
        }
        return next
    }
}
