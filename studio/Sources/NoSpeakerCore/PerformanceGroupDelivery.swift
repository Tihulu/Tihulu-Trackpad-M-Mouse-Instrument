import Foundation

/// A synchronous injected MIDI sink. Acceptance means the local send returned
/// success, never that a DAW received the event or produced sound.
public struct PerformanceGroupDelivery: Sendable {
    public struct Report: Equatable, Sendable {
        public fileprivate(set) var accepted = 0
        public fileprivate(set) var capacityRefused = 0
        public fileprivate(set) var failedGroups: Set<UUID> = []
        public fileprivate(set) var pendingCleanup: Set<UUID> = []
        public fileprivate(set) var admissionExpired = false
        public init() {}

        static var rejectedReceipt: Self {
            var result = Self()
            result.admissionExpired = true
            return result
        }

        // Dynamic pool reports retain capacity refusal separately from
        // transport failure. Accepted counts reconciled logical deliveries.
        init(dynamic:DynamicMPEGroupDelivery.Report) {
            accepted = dynamic.delivered
            admissionExpired = dynamic.admissionExpired
            capacityRefused = dynamic.capacityRefused
            failedGroups = dynamic.failedGroups
            pendingCleanup = dynamic.pendingCleanup
        }

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

    /// Receipt-bound frame for the live input adapters. The router is
    /// speculative until the wire batch completes. On expiry, roll back
    /// silent joins and unattempted groups; retire only groups whose wire
    /// state may have changed. The caller must batch-disconnect the expired
    /// source with other departing leases, even when nothing was attempted.
    mutating func admittedFrame(lease:UUID,sequence:UInt64,now:Double,
                                values:[SensorSignal:Double],releasing:Set<SensorSignal>,
                                admit:()->Bool,send:(PerformanceGroupCommand)->Bool) -> Report {
        guard admit() else {
            var report = Report.rejectedReceipt
            report.pendingCleanup = pendingCleanup
            return report
        }
        let previous = router
        let commands = router.frame(lease:lease,sequence:sequence,now:now,values:values,releasing:releasing)
        var attempted:Set<UUID> = []
        var report = deliver(commands,admit:admit,onAttempt:{ attempted.insert($0) },send:send)
        if report.admissionExpired || !admit() {
            report.admissionExpired = true
            router = previous
            // Preserve real transport failures even though the logical
            // snapshot was rolled back. Never create debt for skipped sends.
            for id in attempted.union(report.failedGroups).sorted(by:{ $0.uuidString < $1.uuidString }) {
                _ = router.stopGroup(id)
                guard var output = outputs[id], !output.retired else { continue }
                output.retired = true
                output.faulted = true
                outputs[id] = output
                report.failedGroups.insert(id)
                clean(id,send:send,report:&report)
            }
            report.pendingCleanup = pendingCleanup
        }
        return report
    }

    public mutating func disconnect(_ lease: UUID, send: (PerformanceGroupCommand) -> Bool) -> Report {
        let commands = router.disconnect(lease)
        return deliver(commands,send:send)
    }

    public func hasLease(_ id: UUID) -> Bool { router.hasLease(id) }

    public mutating func disconnectBatch(_ leases: Set<UUID>, send: (PerformanceGroupCommand) -> Bool) -> Report {
        disconnectBatch(leases,admitRestoration:nil,send:send)
    }

    /// A departing owner may restore another owner's non-neutral CC or
    /// bend. Those are live output, not cleanup. Check before and after
    /// such a restoration; never fence actual neutral/off commands.
    mutating func disconnectBatch(_ leases:Set<UUID>,admitRestoration:((PerformanceGroupCommand)->Bool)?,
                                  send:(PerformanceGroupCommand)->Bool) -> Report {
        let commands = router.disconnectBatch(leases)
        return deliver(commands,admitRestoration:admitRestoration,send:send)
    }

    public mutating func expire(now: Double, timeout: Double, send: (PerformanceGroupCommand) -> Bool) -> Report {
        let commands = router.expire(now:now,timeout:timeout)
        return deliver(commands,send:send)
    }

    /// On failure, discard future logical events for that group and neutralize
    /// every attempted non-neutral target, including a failed onset. Other
    /// groups in the same frame continue independently.
    private mutating func deliver(_ commands: [PerformanceGroupCommand],
                                  admit: () -> Bool = { true },
                                  onAttempt: (UUID) -> Void = { _ in },
                                  admitRestoration:((PerformanceGroupCommand)->Bool)? = nil,
                                  send: (PerformanceGroupCommand) -> Bool) -> Report {
        var report = Report()
        for item in commands {
            let id = item.groupID
            guard var output = outputs[id], !output.retired else { continue }
            // Check before touching the ledger. Cleanup itself remains
            // unfenced so an expired input cannot suppress a necessary off.
            guard admit() else { report.admissionExpired = true; break }
            let restoring = !output.ledger.isRelease(item.command)
            if restoring,let admitRestoration,!admitRestoration(item) {
                report.admissionExpired = true
                retire(id,send:send,report:&report)
                continue
            }
            let ok = output.ledger.deliver(item.command) { command in
                onAttempt(id)
                return send(.init(groupID:id,command:command))
            }
            outputs[id] = output
            if ok {
                report.accepted += 1
                if restoring,let admitRestoration,!admitRestoration(item) {
                    report.admissionExpired = true
                    retire(id,send:send,report:&report)
                }
            } else {
                retire(id,send:send,report:&report)
            }
        }
        report.pendingCleanup = pendingCleanup
        return report
    }

    private mutating func retire(_ id:UUID,send:(PerformanceGroupCommand)->Bool,report:inout Report) {
        guard var output = outputs[id],!output.retired else { return }
        report.failedGroups.insert(id)
        // Router releases are logical only. The actual wire ledger owns
        // cleanup, including failed sends, not speculative restorations.
        _ = router.stopGroup(id)
        output.retired = true
        output.faulted = true
        outputs[id] = output
        clean(id,send:send,report:&report)
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
