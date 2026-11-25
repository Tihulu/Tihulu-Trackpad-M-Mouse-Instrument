import Foundation

/// A synchronous injected MIDI sink. Acceptance means the local send returned
/// success, never that a DAW received the event or produced sound.
public struct PerformanceGroupDelivery: Sendable {
    public struct Report: Equatable, Sendable {
        public fileprivate(set) var accepted = 0
        public fileprivate(set) var failedGroups: Set<UUID> = []
        public fileprivate(set) var pendingCleanup: Set<UUID> = []
        public init() {}

        // Merge setup-selector debt without exposing mutable report fields.
        func includingSetupCleanup(_ pending:Set<UUID>,failedGroup:UUID?) -> Self {
            var result = self
            result.pendingCleanup.formUnion(pending)
            if let failedGroup { result.failedGroups.insert(failedGroup) }
            return result
        }
    }

    private struct Output: Sendable {
        var ledger: PatchOutputLedger
        var retired = false
        var faulted = false
    }
    private var router: PerformanceGroupRouter
    private var outputs: [UUID: Output] = [:]
    public var sessionCount: Int { router.sessionCount }
    public var retired: Bool { router.retired }
    public var pendingCleanup: Set<UUID> {
        Set(outputs.compactMap { id, output in
            output.retired && !output.ledger.outstanding.isEmpty ? id : nil
        })
    }
    public var faultedGroups: Set<UUID> {
        Set(outputs.compactMap { id, output in output.faulted ? id : nil })
    }

    public init(profile: PerformanceGroupProfile, allowLayering: Bool = false) throws {
        router = try PerformanceGroupRouter(profile:profile,allowLayering:allowLayering)
        for group in profile.groups where !group.patch.routes.isEmpty {
            var ledger = PatchOutputLedger()
            try ledger.configure(group.patch)
            outputs[group.id] = Output(ledger:ledger)
        }
    }

    public mutating func connect(_ source: SensorSource, now: Double) throws -> UUID {
        try router.connect(source,now:now)
    }

    public mutating func frame(lease: UUID, sequence: UInt64, now: Double,
                               values: [SensorSignal: Double], releasing: Set<SensorSignal> = [],
                               send: (PerformanceGroupCommand) -> Bool) -> Report {
        let commands = router.frame(lease:lease,sequence:sequence,now:now,values:values,releasing:releasing)
        return deliver(commands,send:send)
    }

    public mutating func disconnect(_ lease: UUID, send: (PerformanceGroupCommand) -> Bool) -> Report {
        let commands = router.disconnect(lease)
        return deliver(commands,send:send)
    }

    public func hasLease(_ id: UUID) -> Bool { router.hasLease(id) }

    public mutating func disconnectBatch(_ leases: Set<UUID>, send: (PerformanceGroupCommand) -> Bool) -> Report {
        let commands = router.disconnectBatch(leases)
        return deliver(commands,send:send)
    }

    public mutating func expire(now: Double, timeout: Double, send: (PerformanceGroupCommand) -> Bool) -> Report {
        let commands = router.expire(now:now,timeout:timeout)
        return deliver(commands,send:send)
    }

    /// On failure, discard future logical events for that group and neutralize
    /// every attempted non-neutral target, including a failed onset. Other
    /// groups in the same frame continue independently.
    private mutating func deliver(_ commands: [PerformanceGroupCommand],
                                  send: (PerformanceGroupCommand) -> Bool) -> Report {
        var report = Report()
        for item in commands {
            let id = item.groupID
            guard var output = outputs[id], !output.retired else { continue }
            let ok = output.ledger.deliver(item.command) { command in
                send(.init(groupID:id,command:command))
            }
            outputs[id] = output
            if ok { report.accepted += 1 }
            else {
                report.failedGroups.insert(id)
                // Router releases are logical only. The ledger is authoritative
                // for wire cleanup and avoids sending unattempted targets.
                _ = router.stopGroup(id)
                output.retired = true
                output.faulted = true
                outputs[id] = output
                clean(id,send:send,report:&report)
            }
        }
        report.pendingCleanup = pendingCleanup
        return report
    }

    /// A normal stop also uses delivery history, not the router's logical
    /// state. Failed cleanup remains attached to the retired endpoint.
    public mutating func stopGroup(_ id: UUID, send: (PerformanceGroupCommand) -> Bool) -> Report {
        var report = Report()
        if var output = outputs[id] {
            _ = router.stopGroup(id)
            output.retired = true
            outputs[id] = output
            clean(id,send:send,report:&report)
        }
        report.pendingCleanup = pendingCleanup
        return report
    }

    public mutating func panic(send: (PerformanceGroupCommand) -> Bool) -> Report {
        _ = router.panic()
        var report = Report()
        for id in outputs.keys.sorted(by:{ $0.uuidString < $1.uuidString }) {
            guard var output = outputs[id] else { continue }
            output.retired = true
            outputs[id] = output
            clean(id,send:send,report:&report)
        }
        report.pendingCleanup = pendingCleanup
        return report
    }

    /// Retry only a retired group's outstanding targets. Never reset a live
    /// group or clear debt merely because a different endpoint is available.
    public mutating func retryCleanup(_ id: UUID, send: (PerformanceGroupCommand) -> Bool) -> Report {
        var report = Report()
        clean(id,send:send,report:&report)
        report.pendingCleanup = pendingCleanup
        return report
    }

    private mutating func clean(_ id: UUID, send: (PerformanceGroupCommand) -> Bool,
                                report: inout Report) {
        guard var output = outputs[id], output.retired else { return }
        let clean = output.ledger.releaseAll { command in
            let accepted = send(.init(groupID:id,command:command))
            if accepted { report.accepted += 1 }
            return accepted
        }
        if !clean {
            output.faulted = true
            report.failedGroups.insert(id)
        }
        outputs[id] = output
    }
}
