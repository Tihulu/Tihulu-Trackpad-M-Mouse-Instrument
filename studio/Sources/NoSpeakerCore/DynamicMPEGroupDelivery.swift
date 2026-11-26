import Foundation

/// Offline all-tuned group candidate. The existing router owns logical
/// first-on/last-off gates; each dedicated port owns its own fixed-bend pool.
/// No native Start, standard fallback, or automatic reconfiguration.
public struct DynamicMPEGroupDelivery: Sendable {
    public enum State:Equatable,Sendable { case unprepared,ready,retired }
    public struct Report:Equatable,Sendable {
        public fileprivate(set) var delivered = 0
        public fileprivate(set) var capacityRefused = 0
        public fileprivate(set) var failedGroups:Set<UUID> = []
        public fileprivate(set) var pendingCleanup:Set<UUID> = []
        public fileprivate(set) var admissionExpired = false
        public init() {}
    }
    public private(set) var state:State = .unprepared
    private var router:PerformanceGroupRouter
    private var pools:[UUID:DynamicMPEPoolSession]
    public var plans:[UUID:DynamicMPEPoolPlan] { pools.mapValues(\.plan) }
    public var pendingCleanup:Set<UUID> { Set(pools.compactMap { $0.value.pendingCleanup ? $0.key : nil }) }
    public var activeGroups:Set<UUID> { Set(pools.compactMap { $0.value.state == .ready ? $0.key : nil }) }
    public var sessionCount:Int { router.sessionCount }
    public var retired:Bool { state == .retired }
    public func hasLease(_ id:UUID) -> Bool { state == .ready && router.hasLease(id) }

    public init(profile:PerformanceGroupProfile,tuning:[UUID:PerformanceGroupTuningPlan.Specification],
                allowLayering:Bool = false) throws {
        let groups = profile.groups.filter { !$0.patch.routes.isEmpty }
        guard !groups.isEmpty,Set(tuning.keys) == Set(groups.map(\.id)) else { throw MIDIClipError.invalidClip }
        _ = try PerformanceGroupEndpointPlan(profile:profile)
        router = try .init(profile:profile,allowLayering:allowLayering)
        var next:[UUID:DynamicMPEPoolSession] = [:]
        for group in groups {
            guard let spec = tuning[group.id] else { throw MIDIClipError.invalidClip }
            next[group.id] = try .init(plan:.init(patch:group.patch,specification:spec))
        }
        pools = next
    }

    public mutating func prepare(send:(PerformanceGroupCommand)->Bool) -> Bool {
        guard state == .unprepared else { return false }
        for id in pools.keys.sorted(by:{ $0.uuidString < $1.uuidString }) {
            guard var pool = pools[id] else { continue }
            let ok = pool.prepare { send(.init(groupID:id,command:$0)) }
            pools[id] = pool
            if !ok {
                _ = panic(send:send)
                return false
            }
        }
        state = .ready
        return true
    }

    public mutating func connect(_ source:SensorSource,now:Double) throws -> UUID {
        guard state == .ready else { throw PerformanceGroupTunedDelivery.AdmissionError.notReady }
        return try router.connect(source,now:now)
    }

    public mutating func frame(lease:UUID,sequence:UInt64,now:Double,
                               values:[SensorSignal:Double],releasing:Set<SensorSignal> = [],
                               send:(PerformanceGroupCommand)->Bool) -> Report {
        guard state == .ready else { return Report(pending:pendingCleanup) }
        let commands = router.frame(lease:lease,sequence:sequence,now:now,values:values,releasing:releasing)
        return deliver(commands,send:send)
    }

    /// Each pool receive emits at most one ordinary wire command; its
    /// internal failure cleanup is deliberately outside the receipt fence.
    /// Roll back pure capacity/suppression changes for unattempted pools.
    mutating func admittedFrame(lease:UUID,sequence:UInt64,now:Double,
                                values:[SensorSignal:Double],releasing:Set<SensorSignal>,
                                admit:()->Bool,send:(PerformanceGroupCommand)->Bool) -> Report {
        guard state == .ready,admit() else {
            var report = Report(pending:pendingCleanup)
            report.admissionExpired = true
            return report
        }
        let previous = router
        let previousPools = pools
        let commands = router.frame(lease:lease,sequence:sequence,now:now,values:values,releasing:releasing)
        var attempted:Set<UUID> = []
        var report = deliver(commands,admit:admit,onAttempt:{ attempted.insert($0) },send:send)
        if report.admissionExpired || !admit() {
            report.admissionExpired = true
            router = previous
            let affected = attempted.union(report.failedGroups)
            for id in previousPools.keys where !affected.contains(id) {
                pools[id] = previousPools[id]
            }
            // Refusals from a rejected logical frame are not committed.
            report.capacityRefused = 0
            for id in affected.sorted(by:{ $0.uuidString < $1.uuidString }) {
                _ = router.stopGroup(id)
                guard var pool = pools[id],pool.state != .retired else { continue }
                report.failedGroups.insert(id)
                _ = pool.stop { send(.init(groupID:id,command:$0)) }
                pools[id] = pool
            }
            report.pendingCleanup = pendingCleanup
        }
        return report
    }

    public mutating func disconnectBatch(_ leases:Set<UUID>,send:(PerformanceGroupCommand)->Bool) -> Report {
        guard state == .ready else { return Report(pending:pendingCleanup) }
        let commands = router.disconnectBatch(leases)
        return deliver(commands,send:send)
    }

    public mutating func expire(now:Double,timeout:Double,send:(PerformanceGroupCommand)->Bool) -> Report {
        guard state == .ready else { return Report(pending:pendingCleanup) }
        let commands = router.expire(now:now,timeout:timeout)
        return deliver(commands,send:send)
    }

    private mutating func deliver(_ commands:[PerformanceGroupCommand],
                                  admit:()->Bool = { true },onAttempt:(UUID)->Void = { _ in },
                                  send:(PerformanceGroupCommand)->Bool) -> Report {
        var report = Report()
        for item in commands {
            guard var pool = pools[item.groupID],pool.state == .ready else { continue }
            guard admit() else { report.admissionExpired = true; break }
            let result = pool.receive(item.command) {
                onAttempt(item.groupID)
                return send(.init(groupID:item.groupID,command:$0))
            }
            switch result {
            case .delivered: report.delivered += 1
            case .capacity: report.capacityRefused += 1
            case .ignored: break
            case .failed,.invalid,.notReady:
                report.failedGroups.insert(item.groupID)
                _ = router.stopGroup(item.groupID)
                if pool.state != .retired { _ = pool.stop { send(.init(groupID:item.groupID,command:$0)) } }
            }
            pools[item.groupID] = pool
        }
        report.pendingCleanup = pendingCleanup
        return report
    }

    public mutating func stopGroup(_ id:UUID,send:(PerformanceGroupCommand)->Bool) -> Report {
        var report = Report()
        if var pool = pools[id] {
            _ = router.stopGroup(id)
            if !pool.stop(send:{ send(.init(groupID:id,command:$0)) }) { report.failedGroups.insert(id) }
            pools[id] = pool
        }
        report.pendingCleanup = pendingCleanup
        return report
    }

    public mutating func panic(send:(PerformanceGroupCommand)->Bool) -> Report {
        state = .retired
        _ = router.panic()
        var report = Report()
        for id in pools.keys.sorted(by:{ $0.uuidString < $1.uuidString }) {
            guard var pool = pools[id] else { continue }
            if !pool.stop(send:{ send(.init(groupID:id,command:$0)) }) { report.failedGroups.insert(id) }
            pools[id] = pool
        }
        report.pendingCleanup = pendingCleanup
        return report
    }

    public mutating func retryCleanup(_ id:UUID,send:(PerformanceGroupCommand)->Bool) -> Report {
        var report = Report()
        if var pool = pools[id],pool.state == .retired {
            if !pool.retryCleanup(send:{ send(.init(groupID:id,command:$0)) }) { report.failedGroups.insert(id) }
            pools[id] = pool
        }
        report.pendingCleanup = pendingCleanup
        return report
    }
}

private extension DynamicMPEGroupDelivery.Report {
    init(pending:Set<UUID>) {
        self.init()
        pendingCleanup = pending
    }
}
