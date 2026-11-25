import Foundation

/// Device-specific input policy for the group engine. This does not enumerate
/// controllers or open hardware. The native adapter must supply a frozen,
/// explicitly selected slot and its binding token, on a serialized executor.
public struct PerformanceGroupGamepadSession: Sendable {
    public enum AdmissionError: Error, Equatable {
        case unsupportedProfile, invalidSlot, alreadyBound, retired, invalidTime
    }
    public enum Status: Equatable, Sendable {
        case ignored, waitingForNeutral, ready, delivered, lost, admissionRejected
    }
    public struct Result: Sendable {
        public let status: Status
        public let reports: [PerformanceGroupDelivery.Report]
    }
    private struct Binding: Sendable {
        let token: UUID
        var armed = false
        var lease: UUID?
        var lastSeen: Double?
        var sequence: UInt64 = 0
        var lastActive: [SensorSignal:Double]?
        mutating func reset() {
            armed = false; lease = nil; lastSeen = nil; sequence = 0; lastActive = nil
        }
    }

    public static let timeout = PhysicalPatchRuntime.timeout
    private var delivery: PerformanceGroupDelivery
    private let mapped: [SensorSource:Set<SensorSignal>]
    private let smoothed: Set<SensorSource>
    private var bindings: [SensorSource:Binding] = [:]
    private var clock = 0.0
    public var boundSources: Set<SensorSource> { Set(bindings.keys) }
    public var activeSessions: Int { delivery.sessionCount }
    public var pendingCleanup: Set<UUID> { delivery.pendingCleanup }
    public var retired: Bool { delivery.retired }

    /// First native adapter slice is deliberately gamepad-only; reject
    /// mixed profiles rather than silently ignoring their other sources.
    public init(profile: PerformanceGroupProfile, allowLayering: Bool = false) throws {
        let routes = profile.groups.flatMap { $0.patch.routes }
        guard profile.isValid, !routes.isEmpty,
              routes.allSatisfy({ GamepadFrame.sources.contains($0.source) && GamepadFrame.permits($0) }) else {
            throw AdmissionError.unsupportedProfile
        }
        mapped = Dictionary(grouping:routes,by:{ $0.source }).mapValues { Set($0.map(\.signal)) }
        smoothed = Set(routes.filter { ($0.response?.smoothingMS ?? 0) > 0 }.map(\.source))
        delivery = try PerformanceGroupDelivery(profile:profile,allowLayering:allowLayering)
    }

    public mutating func bind(_ source: SensorSource, now: Double) throws -> UUID {
        guard !retired else { throw AdmissionError.retired }
        guard mapped[source] != nil else { throw AdmissionError.invalidSlot }
        guard bindings[source] == nil else { throw AdmissionError.alreadyBound }
        guard now.isFinite, now >= clock else { throw AdmissionError.invalidTime }
        clock = now
        let token = UUID()
        bindings[source] = Binding(token:token)
        return token
    }

    /// A complete snapshot, never a delta. No held button or trigger at
    /// startup or after a stall can sound until a neutral snapshot arrives.
    public mutating func receive(_ source: SensorSource, token: UUID,
                                 frame: GamepadFrame?, now: Double,
                                 send: (PerformanceGroupCommand) -> Bool) -> Result {
        guard !retired, bindings[source]?.token == token else {
            return .init(status:.ignored,reports:[])
        }
        guard now.isFinite, now >= clock else {
            let reports = reset(Set(bindings.keys),send:send)
            return .init(status:.lost,reports:reports)
        }
        clock = now
        let expired = staleSources(now:now)
        var reports = reset(expired,send:send)
        if expired.contains(source) {
            return .init(status:.lost,reports:reports)
        }
        guard var binding = bindings[source] else {
            return .init(status:.ignored,reports:reports)
        }
        guard let frame else {
            reports += reset([source],send:send)
            return .init(status:.lost,reports:reports)
        }
        if let lease = binding.lease, !delivery.hasLease(lease) {
            binding.reset()
        }
        binding.lastSeen = now
        if !binding.armed {
            binding.armed = frame.active.isEmpty
            bindings[source] = binding
            return .init(status:binding.armed ? .ready : .waitingForNeutral,reports:reports)
        }
        let signals = mapped[source] ?? []
        let values = frame.active.filter { signals.contains($0.key) }
        if binding.lease == nil {
            guard !values.isEmpty else {
                bindings[source] = binding
                return .init(status:.ready,reports:reports)
            }
            do {
                binding.lease = try delivery.connect(source,now:now)
            } catch {
                binding.reset()
                bindings[source] = binding
                return .init(status:.admissionRejected,reports:reports)
            }
        }
        guard let lease = binding.lease else {
            return .init(status:.admissionRejected,reports:reports)
        }
        // Skip unchanged unsmoothed snapshots; this adapter owns expiry and
        // still renews lastSeen. Smoothed controls require repeated samples.
        if !smoothed.contains(source), binding.lastActive == values {
            bindings[source] = binding
            return .init(status:.ready,reports:reports)
        }
        let stride = UInt64(SensorSignal.allCases.count+1)
        guard binding.sequence < (UInt64.max-stride)/stride else {
            reports += reset([source],send:send)
            return .init(status:.lost,reports:reports)
        }
        binding.sequence += 1
        binding.lastActive = values
        bindings[source] = binding
        reports.append(delivery.frame(lease:lease,sequence:binding.sequence,now:now,
            values:values,releasing:signals.subtracting(values.keys),send:send))
        if !delivery.hasLease(lease) { bindings[source]?.reset() }
        return .init(status:.delivered,reports:reports)
    }

    /// Host must call at the existing watchdog cadence. No change to the
    /// physical deadline, and no timeout renewal by unrelated controllers.
    public mutating func expire(now: Double, send: (PerformanceGroupCommand) -> Bool) -> [PerformanceGroupDelivery.Report] {
        guard !retired else { return [] }
        guard now.isFinite, now >= clock else { return reset(Set(bindings.keys),send:send) }
        clock = now
        return reset(staleSources(now:now),send:send)
    }

    /// Actual unplug or deliberate detach retires the binding token; a new
    /// physical device must be explicitly bound, never auto-substituted.
    public mutating func unbind(_ source: SensorSource, token: UUID,
                                send: (PerformanceGroupCommand) -> Bool) -> [PerformanceGroupDelivery.Report] {
        guard bindings[source]?.token == token else { return [] }
        let reports = reset([source],send:send)
        bindings.removeValue(forKey:source)
        return reports
    }

    public mutating func stopGroup(_ id: UUID, send: (PerformanceGroupCommand) -> Bool) -> PerformanceGroupDelivery.Report {
        delivery.stopGroup(id,send:send)
    }
    public mutating func panic(send: (PerformanceGroupCommand) -> Bool) -> PerformanceGroupDelivery.Report {
        bindings.removeAll()
        return delivery.panic(send:send)
    }
    public mutating func retryCleanup(_ id: UUID, send: (PerformanceGroupCommand) -> Bool) -> PerformanceGroupDelivery.Report {
        delivery.retryCleanup(id,send:send)
    }

    private func staleSources(now: Double) -> Set<SensorSource> {
        Set(bindings.compactMap { source,binding in
            guard let last = binding.lastSeen, now-last >= Self.timeout else { return nil }
            return source
        })
    }

    private mutating func reset(_ sources: Set<SensorSource>,
                                send: (PerformanceGroupCommand) -> Bool) -> [PerformanceGroupDelivery.Report] {
        var leases: Set<UUID> = []
        for source in sources {
            guard var binding = bindings[source] else { continue }
            if let lease = binding.lease { leases.insert(lease) }
            binding.reset()
            bindings[source] = binding
        }
        guard !leases.isEmpty else { return [] }
        return [delivery.disconnectBatch(leases,send:send)]
    }
}
