/// Outgoing continuous controller arbitration for one virtual MIDI source.
/// Priority is fixed, not arrival-time dependent. An active lower-priority
/// owner retains its latest value; releasing the winner restores that value.
public struct LegacyContinuousOwners: Sendable {
    public enum Owner: Int, Hashable, Sendable {
        case touch = 0, legacyTouch = 1, helper = 2, touchBar = 3
    }
    public struct Value: Equatable, Sendable {
        public let value: Int
        public let neutral: Int
        public let bendRange: Int?
        public let preserveOnRelease:Bool
        public init(_ value: Int, neutral: Int, bendRange: Int? = nil,preserveOnRelease:Bool = false) {
            self.value = value; self.neutral = neutral; self.bendRange = bendRange; self.preserveOnRelease = preserveOnRelease
        }
        fileprivate func valid(for target: SensorDestination) -> Bool {
            guard target.isValid, !preserveOnRelease || (target.kind == .controlChange && [7,11].contains(target.number)) else { return false }
            switch target.kind {
            case .controlChange:
                return HelperCCPolicy.permits(target.number) && (0...127).contains(value) &&
                    (0...127).contains(neutral) && bendRange == nil
            case .pitchBend:
                return (0...16383).contains(value) && neutral == 8192 &&
                    (bendRange.map { (1...24).contains($0) } ?? true)
            default: return false
            }
        }
    }
    public struct Update: Equatable, Sendable {
        public let target: SensorDestination
        public let value: Int
        /// Send RPN only on effective range change, before the bend value.
        public let bendRange: Int?
        public let neutral: Int
        public let preserveOnRelease:Bool
        public init(_ target: SensorDestination, value: Int, bendRange: Int? = nil, neutral: Int? = nil,preserveOnRelease:Bool = false) {
            self.target = target; self.value = value; self.bendRange = bendRange; self.preserveOnRelease = preserveOnRelease
            self.neutral = neutral ?? (target.kind == .pitchBend ? 8192 : ([7,11].contains(target.number) ? 127 : 0))
        }
    }

    private var owners: [Owner:[SensorDestination:Value]] = [:]
    public init() {}
    public func values(for owner: Owner) -> [SensorDestination:Value] { owners[owner] ?? [:] }

    private func winner(_ target: SensorDestination) -> Value? {
        for owner in [Owner.touch,.legacyTouch,.helper,.touchBar] {
            if let value = owners[owner]?[target] { return value }
        }
        return nil
    }
    private func sorted(_ targets: Set<SensorDestination>) -> [SensorDestination] {
        targets.sorted {
            if $0.channel != $1.channel { return $0.channel < $1.channel }
            if $0.kind != $1.kind { return $0.kind.rawValue < $1.kind.rawValue }
            return $0.number < $1.number
        }
    }

    public mutating func replace(_ owner: Owner, values: [SensorDestination:Value]) -> [Update] {
        guard values.allSatisfy({ $0.value.valid(for:$0.key) }) else { return [] }
        let old = self.values(for:owner)
        guard old != values else { return [] }
        // Only destinations whose intent changed can acquire a new winner.
        let changed = Set(old.keys).union(values.keys).filter { old[$0] != values[$0] }
        let targets = sorted(changed)
        let before = targets.map { winner($0) }
        if values.isEmpty { owners.removeValue(forKey:owner) } else { owners[owner] = values }
        return targets.enumerated().compactMap { index,target in
            Self.transition(target, from:before[index], to:winner(target))
        }
    }

    private static func transition(_ target: SensorDestination, from previous: Value?, to next: Value?) -> Update? {
        if let next {
            let rangeChanged = previous?.bendRange != next.bendRange
            guard previous?.value != next.value || previous?.neutral != next.neutral || previous?.preserveOnRelease != next.preserveOnRelease || rangeChanged else { return nil }
            return .init(target,value:next.value,bendRange:rangeChanged ? next.bendRange : nil,neutral:next.neutral,preserveOnRelease:next.preserveOnRelease)
        }
        guard let previous, !previous.preserveOnRelease, previous.value != previous.neutral else { return nil }
        return .init(target,value:previous.neutral,neutral:previous.neutral)
    }

    public mutating func set(_ owner: Owner, target: SensorDestination, value: Value) -> [Update] {
        guard value.valid(for:target), owners[owner]?[target] != value else { return [] }
        let previous = winner(target)
        owners[owner,default:[:]][target] = value
        return Self.transition(target,from:previous,to:winner(target)).map { [$0] } ?? []
    }
    public mutating func release(_ owner: Owner, channel: Int? = nil) -> [Update] {
        replace(owner,values:channel.map { ch in values(for:owner).filter { $0.key.channel != ch } } ?? [:])
    }
    public mutating func releaseAll() -> [Update] {
        let targets = sorted(Set(owners.values.flatMap(\.keys)))
        let result: [Update] = targets.compactMap { target in
            guard let previous = winner(target), !previous.preserveOnRelease, previous.value != previous.neutral else { return nil }
            return .init(target,value:previous.neutral,neutral:previous.neutral)
        }
        owners.removeAll()
        return result
    }
}
