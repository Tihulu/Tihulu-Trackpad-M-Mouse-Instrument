import Foundation

/// Experimental fixed-bend pool with dynamic note ownership. More than
/// fifteen mapped pitches are possible, never more than fifteen simultaneous
/// members. A member is never retuned during the lifetime of this plan.
public struct DynamicMPEPoolPlan: Sendable {
    public let members:[TunedMIDIClip.Member]
    public let setupCommands:[SensorCommand]
    public let mappedNoteCount:Int
    public let channelsPerBend:[Int:Int]
    fileprivate let notes:[SensorDestination:Int]
    fileprivate let controls:Set<SensorDestination>

    /// Logical destinations have no permanent member address. The preview
    /// lists possible wire destinations, never a promised allocation.
    public func possibleChannels(for target:SensorDestination) -> [Int] {
        if let bend = notes[target] {
            return members.filter { $0.bend == bend }.map { $0.channel+1 }
        }
        return controls.contains(target) ? [1] : []
    }

    public init(patch:InstrumentPatch,specification:PerformanceGroupTuningPlan.Specification) throws {
        let scale = specification.scale, root = specification.root
        guard patch.isValid,scale.isValid,scale.isMicrotonal,(0...127).contains(root),
              Set(patch.routes.map(\.destination.channel)).count == 1 else { throw MIDIClipError.invalidClip }
        // Sostenuto, hold-2 and other CC effects need their own ownership
        // semantics before member recycling. Refuse them in this slice.
        guard patch.routes.allSatisfy({ route in
            switch route.destination.kind {
            case .note,.sustain: return true
            case .pitchBend: return (route.response?.releaseValue(for:route.destination) ?? 8192) == 8192
            case .controlChange: return false
            }
        }) else { throw MIDIClipError.invalidClip }
        var pitches:[SensorDestination:Int] = [:]
        for target in Set(patch.routes.map(\.destination)) where target.kind == .note {
            guard scale.intervals.contains((target.number-root+144)%12),
                  let pitch = scale.mpePitch(midi:target.number,root:root) else { throw MIDIClipError.invalidNote }
            pitches[target] = pitch.bend
        }
        guard !pitches.isEmpty else { throw MIDIClipError.invalidClip }
        let bends = Array(Set(pitches.values)).sorted()
        guard bends.count <= 15 else { throw MIDIClipError.tuningCapacity }
        // Guarantee at least one member for every configured intonation.
        // Distribute the remainder evenly, weighted only by remaining mapped
        // pitch demand. A spare channel is reserved for same-note retriggers
        // under sustain even if the pool contains fewer distinct pitches.
        var counts = Dictionary(uniqueKeysWithValues:bends.map { ($0,1) })
        while counts.values.reduce(0,+) < 15 {
            guard let next = bends.min(by:{ a,b in
                let ca = counts[a] ?? 0, cb = counts[b] ?? 0
                let da = pitches.values.filter { $0 == a }.count
                let db = pitches.values.filter { $0 == b }.count
                // Compare demand/member ratios without floating point.
                let left = da*cb, right = db*ca
                return left == right ? a < b : left > right
            }) else { break }
            counts[next,default:0] += 1
        }
        var allocated:[TunedMIDIClip.Member] = []
        for bend in bends {
            for _ in 0..<(counts[bend] ?? 0) {
                allocated.append(.init(channel:allocated.count+1,bend:bend))
            }
        }
        notes = pitches
        controls = Set(patch.routes.map(\.destination).filter { $0.kind != .note })
        mappedNoteCount = pitches.count
        members = allocated
        channelsPerBend = counts
        setupCommands = TunedMIDIClip.setup(members:allocated) + [.init(.init(.sustain),value:0)]
    }
}

/// One dedicated port with a synchronous injected sink, no native activation.
/// Only reconciled logical gates are accepted. A failed send retires the
/// session permanently and retains exact wire cleanup debt.
public struct DynamicMPEPoolSession: Sendable {
    public enum State: Equatable,Sendable { case unprepared,ready,retired }
    public enum Result: Equatable,Sendable { case delivered,ignored,capacity,invalid,notReady,failed }
    public let plan:DynamicMPEPoolPlan
    public private(set) var state:State = .unprepared
    private var selectors = MIDISelectorCleanup()
    private var active:[SensorDestination:Int] = [:]
    private var sustained:Set<Int> = []
    private var suppressed:Set<SensorDestination> = []
    private var pedal = false
    private var pedalDebt = false
    private var bendDebt = false
    public var activeCount:Int { active.count }
    public var reservedCount:Int { sustained.count }
    public var suppressedCount:Int { suppressed.count }
    public var pendingCleanup:Bool {
        state == .retired && (!selectors.isEmpty || !active.isEmpty || pedalDebt || bendDebt)
    }

    public init(plan:DynamicMPEPoolPlan) { self.plan = plan }

    public mutating func prepare(send:(SensorCommand)->Bool) -> Bool {
        guard state == .unprepared else { return false }
        state = .retired
        // Even failed initial master neutral writes require retry. Never
        // reopen a partly configured port or retry setup in place.
        bendDebt = true
        pedalDebt = true
        let ok = selectors.configure(plan.setupCommands,send:send)
        if ok { bendDebt = false; pedalDebt = false; state = .ready }
        else { _ = retryCleanup(send:send) }
        return ok
    }

    public mutating func receive(_ command:SensorCommand,send:(SensorCommand)->Bool) -> Result {
        guard state == .ready else { return .notReady }
        let target = command.destination, value = command.value
        if target.kind == .note {
            guard let bend = plan.notes[target],(0...127).contains(value) else { return .invalid }
            if value == 0 {
                if suppressed.remove(target) != nil { return .ignored }
                guard let channel = active[target] else { return .ignored }
                let wire = SensorDestination(.note,channel:channel,number:target.number)
                guard send(.init(wire,value:0)) else { return fail(send:send) }
                active.removeValue(forKey:target)
                if pedal { sustained.insert(channel) }
                return .delivered
            }
            guard active[target] == nil,!suppressed.contains(target) else { return .ignored }
            let used = Set(active.values).union(sustained)
            guard let member = plan.members.first(where:{ $0.bend == bend && !used.contains($0.channel) }) else {
                // A refused logical onset remains suppressed until its own
                // release. Never steal a voice or replay it automatically.
                suppressed.insert(target)
                return .capacity
            }
            active[target] = member.channel // before attempt: ambiguous failure
            let wire = SensorDestination(.note,channel:member.channel,number:target.number)
            guard send(.init(wire,value:value)) else { return fail(send:send) }
            return .delivered
        }
        guard plan.controls.contains(target) else { return .invalid }
        var master = target
        master.channel = 0
        switch target.kind {
        case .sustain:
            guard value == 0 || value == 127 else { return .invalid }
            if value == 127 { pedalDebt = true }
            guard send(.init(master,value:value)) else { return fail(send:send) }
            pedal = value == 127
            if !pedal { sustained.removeAll(); pedalDebt = false }
        case .pitchBend:
            guard (0...16383).contains(value) else { return .invalid }
            if value != 8192 { bendDebt = true }
            guard send(.init(master,value:value)) else { return fail(send:send) }
            if value == 8192 { bendDebt = false }
        default: return .invalid
        }
        return .delivered
    }

    private mutating func fail(send:(SensorCommand)->Bool) -> Result {
        _ = stop(send:send)
        return .failed
    }

    @discardableResult
    public mutating func stop(send:(SensorCommand)->Bool) -> Bool {
        state = .retired
        suppressed.removeAll()
        return retryCleanup(send:send)
    }

    /// Retry the original wire destinations, never another member. Retain
    /// failed releases even if the master pedal release already succeeded.
    @discardableResult
    public mutating func retryCleanup(send:(SensorCommand)->Bool) -> Bool {
        guard state == .retired else { return false }
        for (note,channel) in active.sorted(by:{ $0.value < $1.value }) {
            if send(.init(.init(.note,channel:channel,number:note.number),value:0)) {
                active.removeValue(forKey:note)
            }
        }
        if pedalDebt,send(.init(.init(.sustain),value:0)) {
            pedalDebt = false
            pedal = false
            sustained.removeAll()
        }
        if bendDebt,send(.init(.init(.pitchBend),value:8192)) { bendDebt = false }
        _ = selectors.releaseAll(send:send)
        return !pendingCleanup
    }
}
