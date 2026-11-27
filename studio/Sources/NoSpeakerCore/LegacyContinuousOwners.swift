import Foundation

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
    private struct RelativeReservation: Sendable {
        let token: UUID
        let targets: Set<SensorDestination>
        var retired = false
    }
    private var relativeReservation: RelativeReservation?

    /// The token is a local logical lease, not an endpoint or delivery claim.
    public mutating func reserveRelativeHelper(targets: Set<SensorDestination>) -> UUID? {
        guard relativeReservation == nil, !targets.isEmpty,
              targets.allSatisfy({ ContinuousResponse.permitsRelative($0) &&
                  ($0.kind != .controlChange || HelperCCPolicy.permits($0.number)) }),
              values(for: .helper).isEmpty,
              [Owner.touch, .legacyTouch, .touchBar].allSatisfy({ targets.isDisjoint(with: values(for: $0).keys) }) else { return nil }
        let token = UUID()
        relativeReservation = .init(token: token, targets: targets)
        return token
    }

    public func permitsRelativeHelper(_ token: UUID) -> Bool {
        relativeReservation?.token == token && relativeReservation?.retired == false
    }

    public mutating func invalidateRelativeHelper(_ token: UUID) {
        guard relativeReservation?.token == token else { return }
        relativeReservation?.retired = true
    }

    /// Only the holder can clear a retired lease after actual cleanup.
    public mutating func finishRelativeHelper(_ token: UUID, transportClean: Bool) -> Bool {
        guard transportClean, relativeReservation?.token == token,
              relativeReservation?.retired == true, values(for: .helper).isEmpty else { return false }
        relativeReservation = nil
        return true
    }

    private func conflictsWithRelative(_ owner: Owner, values: [SensorDestination:Value]) -> Bool {
        guard let reservation = relativeReservation else { return false }
        return owner == .helper || !reservation.targets.isDisjoint(with: values.keys)
    }

    /// Withdraw the entire relative intent before a competing owner enters.
    /// Never retain a hidden relative fallback. If a wire cleanup is denied
    /// or fails, the host's actual-attempt ledger still owns that debt.
    private mutating func withdrawRelative() -> [Update] {
        relativeReservation?.retired = true
        return replaceRaw(.helper, values: [:])
    }
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
        if conflictsWithRelative(owner, values: values) {
            let cleanup = withdrawRelative()
            // Untokened helper writes are not relative movement.
            if owner == .helper { return cleanup }
            return cleanup + replaceRaw(owner, values: values)
        }
        return replaceRaw(owner, values: values)
    }

    private mutating func replaceRaw(_ owner: Owner, values: [SensorDestination:Value]) -> [Update] {
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

    /// Advance intended ownership only for individually admitted, completed
    /// target updates. Failed wire attempts remain the transport's debt;
    /// no untouched target is installed merely because it was in the frame.
    public mutating func replaceAdmitted(_ owner:Owner,values:[SensorDestination:Value],
                                         permits:()->Bool,send:(Update)->Bool)->Bool {
        guard values.allSatisfy({ $0.value.valid(for:$0.key) }) else { return false }
        if conflictsWithRelative(owner, values: values) {
            guard permits() else { return false }
            let cleanup = withdrawRelative()
            for update in cleanup {
                guard permits(), send(update) else { return false }
            }
            if owner == .helper { return values.isEmpty && permits() }
        }
        return replaceAdmittedRaw(owner, values: values, permits: permits, send: send)
    }

    /// Tokened relative movement never runs through untokened legacy paths.
    public mutating func replaceRelativeHelperAdmitted(_ token: UUID, values: [SensorDestination:Value],
                                                        permits: () -> Bool, send: (Update) -> Bool) -> Bool {
        guard permitsRelativeHelper(token), let reservation = relativeReservation,
              values.allSatisfy({ reservation.targets.contains($0.key) && $0.value.valid(for: $0.key) &&
                                  $0.value.bendRange == nil }) else { return false }
        let accepted = replaceAdmittedRaw(.helper, values: values, permits: permits, send: send)
        if !accepted { invalidateRelativeHelper(token) }
        return accepted
    }

    private mutating func replaceAdmittedRaw(_ owner: Owner, values: [SensorDestination:Value],
                                             permits: () -> Bool, send: (Update) -> Bool) -> Bool {
        let old=self.values(for:owner)
        let targets=sorted(Set(old.keys).union(values.keys).filter { old[$0] != values[$0] })
        for target in targets {
            guard permits() else { return false }
            var next=self.values(for:owner)
            next[target]=values[target]
            var candidate=self
            let updates=candidate.replaceRaw(owner,values:next)
            for update in updates {
                guard permits(),send(update) else { return false }
            }
            self=candidate
        }
        return permits()
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
        guard value.valid(for:target) else { return [] }
        if conflictsWithRelative(owner, values: [target:value]) {
            var next = values(for: owner)
            next[target] = value
            return replace(owner, values: next)
        }
        guard owners[owner]?[target] != value else { return [] }
        let previous = winner(target)
        owners[owner,default:[:]][target] = value
        return Self.transition(target,from:previous,to:winner(target)).map { [$0] } ?? []
    }
    public mutating func release(_ owner: Owner, channel: Int? = nil) -> [Update] {
        if owner == .helper, let reservation = relativeReservation {
            guard channel.map({ ch in reservation.targets.contains(where: { $0.channel == ch }) }) ?? true else { return [] }
            return withdrawRelative()
        }
        return replace(owner,values:channel.map { ch in values(for:owner).filter { $0.key.channel != ch } } ?? [:])
    }
    public mutating func releaseAll() -> [Update] {
        let targets = sorted(Set(owners.values.flatMap(\.keys)))
        let result: [Update] = targets.compactMap { target in
            guard let previous = winner(target), !previous.preserveOnRelease, previous.value != previous.neutral else { return nil }
            return .init(target,value:previous.neutral,neutral:previous.neutral)
        }
        owners.removeAll()
        relativeReservation?.retired = true
        return result
    }
}


/// Physical bend range transaction. The selector reset is cleanup, not
/// a fresh performance command. Never send a late data entry; expose
/// incomplete/ambiguous range writes instead of claiming success.
public enum LegacyAdmittedBendRange {
    public struct Result: Equatable, Sendable {
        public let completed:Bool
        public let attempted:Bool
        public let dataAttempted:Bool
        public let cleanupConfirmed:Bool
    }
    public static func send(semitones:Int,permits:()->Bool,begin:()->Void,
                            wire:(Int,Int)->Bool)->Result {
        guard permits() else {
            return .init(completed:false,attempted:false,dataAttempted:false,cleanupConfirmed:true)
        }
        var dataAttempted=false
        var completed=true
        let parts=[(101,0),(100,0),(6,max(0,min(24,semitones))),(38,0)]
        for (index,part) in parts.enumerated() {
            let (cc,value)=part
            // The initial permit authorizes exactly the first attempt.
            // Do not create range debt or send null selectors for a
            // transaction that never reached its first wire call.
            if index==0 { begin() }
            else if !permits() { completed=false;break }
            if cc==6 || cc==38 { dataAttempted=true }
            guard wire(cc,value) else { completed=false;break }
        }
        let msb=wire(101,127)
        let lsb=wire(100,127)
        return .init(completed:completed && msb && lsb,attempted:true,
                     dataAttempted:dataAttempted,cleanupConfirmed:msb && lsb)
    }
}
