import Foundation

/// Injected-sink MPE delivery candidate. The caller owns the independent
/// endpoints and must retain this state until all cleanup debt is cleared.
/// Not a native activation API; no hardware, timer or automatic retry.
public struct PerformanceGroupTunedDelivery: Sendable {
    public enum State: Equatable, Sendable { case unprepared, ready, retired }
    public enum AdmissionError: Error, Equatable { case notReady }
    public let plan: PerformanceGroupTuningPlan
    private var delivery: PerformanceGroupDelivery
    private var selectors: [UUID:MIDISelectorCleanup] = [:]
    public private(set) var state: State = .unprepared
    public var pendingCleanup: Set<UUID> {
        delivery.pendingCleanup.union(selectors.compactMap { $0.value.isEmpty ? nil : $0.key })
    }

    public init(profile:PerformanceGroupProfile,tuning:[UUID:PerformanceGroupTuningPlan.Specification],
                allowLayering:Bool = false) throws {
        plan = try .init(profile:profile,tuning:tuning)
        delivery = try .init(profile:profile,allowLayering:allowLayering)
    }

    /// Setup is all-or-nothing for admission, not a wire rollback. No notes
    /// are admitted until every tuned zone's setup succeeds. If an endpoint
    /// fails, never fall back to untuned playback or rerun setup in place.
    public mutating func prepare(send:(PerformanceGroupCommand)->Bool) -> Bool {
        guard state == .unprepared else { return false }
        state = .retired
        for id in plan.zones.keys.sorted(by:{ $0.uuidString < $1.uuidString }) {
            guard let zone = plan.zones[id] else { continue }
            var selector = MIDISelectorCleanup()
            let ok = selector.configure(zone.setupCommands) { send(.init(groupID:id,command:$0)) }
            selectors[id] = selector
            if !ok {
                _ = retrySelectors(id,send:send)
                return false
            }
        }
        state = .ready
        return true
    }

    public mutating func connect(_ source:SensorSource,now:Double) throws -> UUID {
        guard state == .ready else { throw AdmissionError.notReady }
        return try delivery.connect(source,now:now)
    }

    public mutating func frame(lease:UUID,sequence:UInt64,now:Double,
                               values:[SensorSignal:Double],releasing:Set<SensorSignal> = [],
                               send:(PerformanceGroupCommand)->Bool) -> PerformanceGroupDelivery.Report {
        guard state == .ready else { return .init() }
        let frozen = plan
        return delivery.frame(lease:lease,sequence:sequence,now:now,values:values,releasing:releasing) {
            guard let translated = frozen.translate($0) else { return false }
            return send(translated)
        }
    }

    public mutating func disconnect(_ lease:UUID,send:(PerformanceGroupCommand)->Bool) -> PerformanceGroupDelivery.Report {
        guard state == .ready else { return .init() }
        let frozen = plan
        return delivery.disconnect(lease) {
            guard let translated = frozen.translate($0) else { return false }
            return send(translated)
        }
    }

    public mutating func expire(now:Double,timeout:Double,send:(PerformanceGroupCommand)->Bool) -> PerformanceGroupDelivery.Report {
        guard state == .ready else { return .init() }
        let frozen = plan
        return delivery.expire(now:now,timeout:timeout) {
            guard let translated = frozen.translate($0) else { return false }
            return send(translated)
        }
    }

    public mutating func stopGroup(_ id:UUID,send:(PerformanceGroupCommand)->Bool) -> PerformanceGroupDelivery.Report {
        guard state == .ready else { return .init() }
        let frozen = plan
        return delivery.stopGroup(id) {
            guard let translated = frozen.translate($0) else { return false }
            return send(translated)
        }
    }

    /// Returned report describes musical commands only. The authoritative
    /// close gate is pendingCleanup, including incomplete RPN selectors.
    public mutating func panic(send:(PerformanceGroupCommand)->Bool) -> PerformanceGroupDelivery.Report {
        state = .retired
        let frozen = plan
        let report = delivery.panic {
            guard let translated = frozen.translate($0) else { return false }
            return send(translated)
        }
        for id in selectors.keys.sorted(by:{ $0.uuidString < $1.uuidString }) {
            _ = retrySelectors(id,send:send)
        }
        return report
    }

    /// Retry on the original group's endpoint only. Fixed member bends are
    /// not reset on stop, avoiding retuning already-released note tails.
    public mutating func retryCleanup(_ id:UUID,send:(PerformanceGroupCommand)->Bool) -> Bool {
        let frozen = plan
        _ = delivery.retryCleanup(id) {
            guard let translated = frozen.translate($0) else { return false }
            return send(translated)
        }
        _ = retrySelectors(id,send:send)
        return !pendingCleanup.contains(id)
    }

    private mutating func retrySelectors(_ id:UUID,send:(PerformanceGroupCommand)->Bool) -> Bool {
        guard var selector = selectors[id] else { return true }
        let ok = selector.releaseAll { send(.init(groupID:id,command:$0)) }
        selectors[id] = selector
        return ok
    }
}
