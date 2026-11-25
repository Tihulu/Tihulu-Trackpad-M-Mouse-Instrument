import Foundation

// The same device adapter drives standard, fixed-member and explicitly
// requested dynamic output. Each preserves its own wire cleanup ledger.
private protocol LocalGroupOutput: Sendable {
    var ready: Bool { get }
    var retired: Bool { get }
    var sessionCount: Int { get }
    var pendingCleanup: Set<UUID> { get }
    mutating func prepare(send:(PerformanceGroupCommand)->Bool) -> Bool
    mutating func connect(_ source:SensorSource,now:Double) throws -> UUID
    func hasLease(_ id:UUID) -> Bool
    mutating func frame(lease:UUID,sequence:UInt64,now:Double,values:[SensorSignal:Double],
                        releasing:Set<SensorSignal>,send:(PerformanceGroupCommand)->Bool) -> PerformanceGroupDelivery.Report
    mutating func disconnect(_ lease:UUID,send:(PerformanceGroupCommand)->Bool) -> PerformanceGroupDelivery.Report
    mutating func disconnectBatch(_ leases:Set<UUID>,send:(PerformanceGroupCommand)->Bool) -> PerformanceGroupDelivery.Report
    mutating func stopGroup(_ id:UUID,send:(PerformanceGroupCommand)->Bool) -> PerformanceGroupDelivery.Report
    mutating func panic(send:(PerformanceGroupCommand)->Bool) -> PerformanceGroupDelivery.Report
    mutating func retryCleanupReport(_ id:UUID,send:(PerformanceGroupCommand)->Bool) -> PerformanceGroupDelivery.Report
}
extension PerformanceGroupDelivery: LocalGroupOutput {
    fileprivate var ready: Bool { !retired }
    fileprivate mutating func prepare(send:(PerformanceGroupCommand)->Bool) -> Bool { !retired }
    fileprivate mutating func retryCleanupReport(_ id:UUID,send:(PerformanceGroupCommand)->Bool) -> Report {
        retryCleanup(id,send:send)
    }
}
extension PerformanceGroupTunedDelivery: LocalGroupOutput {
    fileprivate var ready: Bool { state == .ready }
}

/// Adapter preserves the existing device/session fences and report shape.
private struct DynamicLocalGroupOutput: LocalGroupOutput {
    var engine:DynamicMPEGroupDelivery
    var ready:Bool { engine.state == .ready }
    var retired:Bool { engine.retired }
    var sessionCount:Int { engine.sessionCount }
    var pendingCleanup:Set<UUID> { engine.pendingCleanup }
    mutating func prepare(send:(PerformanceGroupCommand)->Bool) -> Bool { engine.prepare(send:send) }
    mutating func connect(_ source:SensorSource,now:Double) throws -> UUID { try engine.connect(source,now:now) }
    func hasLease(_ id:UUID) -> Bool { engine.hasLease(id) }
    mutating func frame(lease:UUID,sequence:UInt64,now:Double,values:[SensorSignal:Double],
                        releasing:Set<SensorSignal>,send:(PerformanceGroupCommand)->Bool) -> PerformanceGroupDelivery.Report {
        .init(dynamic:engine.frame(lease:lease,sequence:sequence,now:now,values:values,releasing:releasing,send:send))
    }
    mutating func disconnect(_ lease:UUID,send:(PerformanceGroupCommand)->Bool) -> PerformanceGroupDelivery.Report {
        disconnectBatch([lease],send:send)
    }
    mutating func disconnectBatch(_ leases:Set<UUID>,send:(PerformanceGroupCommand)->Bool) -> PerformanceGroupDelivery.Report {
        .init(dynamic:engine.disconnectBatch(leases,send:send))
    }
    mutating func stopGroup(_ id:UUID,send:(PerformanceGroupCommand)->Bool) -> PerformanceGroupDelivery.Report {
        .init(dynamic:engine.stopGroup(id,send:send))
    }
    mutating func panic(send:(PerformanceGroupCommand)->Bool) -> PerformanceGroupDelivery.Report {
        .init(dynamic:engine.panic(send:send))
    }
    mutating func retryCleanupReport(_ id:UUID,send:(PerformanceGroupCommand)->Bool) -> PerformanceGroupDelivery.Report {
        .init(dynamic:engine.retryCleanup(id,send:send))
    }
}

/// Device-specific input policy for the group engine. This does not enumerate
/// controllers or open hardware. The native adapter must supply a frozen,
/// explicitly selected slot and its binding token, on a serialized executor.
public struct PerformanceGroupGamepadSession: Sendable {
    public enum AdmissionError: Error, Equatable {
        case unsupportedProfile, invalidSlot, alreadyBound, retired, invalidTime, setupRequired
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
        let boundAt: Double
        var armed = false
        var lease: UUID?
        var lastSeen: Double?
        // Keep the surface receipt fence across resets and ordinary lifts.
        var lastSurfaceReceipt: Double?
        var sequence: UInt64 = 0
        var lastActive: [SensorSignal:Double]?
        var remoteFence = PerformanceGroupRemoteFence()
        var remoteLastReceipt: Double?
        var remoteNeutral: Set<PerformanceGroupRemoteSurface> = []
        var remoteActive: [PerformanceGroupRemoteSurface:Double] = [:]
        mutating func reset() {
            armed = false; lease = nil; lastSeen = nil; sequence = 0; lastActive = nil
        }
    }

    public static let timeout = PhysicalPatchRuntime.timeout
    private var delivery: any LocalGroupOutput
    private let mapped: [SensorSource:Set<SensorSignal>]
    private let smoothed: Set<SensorSource>
    private let remoteModes: [SensorSource:Set<PerformanceGroupRemoteSurface>]
    private let remoteLabels: [SensorSource:[RemoteMappingLabel]]
    private var bindings: [SensorSource:Binding] = [:]
    private var cameraTracking = AirTrackingGate()
    private var clock = 0.0
    public enum SourceState: String, Equatable, Sendable {
        case waitingForNeutral, armed, leased
    }
    /// Local ownership state only. Does not assert a connected physical
    /// device, a successful wire transmission or a sounding DAW track.
    public var sourceStates: [SensorSource:SourceState] {
        bindings.mapValues { binding in
            if let lease = binding.lease {
                return delivery.hasLease(lease) ? .leased : .waitingForNeutral
            }
            return binding.armed ? .armed : .waitingForNeutral
        }
    }
    public var boundSources: Set<SensorSource> { Set(bindings.keys) }
    public var remoteSlots: Set<SensorSource> { Set(remoteModes.keys) }

    public func matchesRemoteBinding(_ source:SensorSource,token:UUID) -> Bool {
        !retired && remoteModes[source] != nil && bindings[source]?.token == token
    }

    /// Logical capabilities only; no group identity, labels or MIDI addresses.
    public func remoteCapabilities(_ source:SensorSource) -> RemoteCapabilities? {
        guard let modes = remoteModes[source], let signals = mapped[source] else { return nil }
        func mask(_ candidates:[SensorSignal]) -> Int {
            candidates.enumerated().reduce(0) { result,item in
                signals.contains(item.element) ? result | (1 << item.offset) : result
            }
        }
        return .init(touch:modes.contains(.xy),tilt:false,acceleration:false,rotation:false,airDrums:false,
                     drums:modes.contains(.drums) ? mask(RemoteDrumPads.signals) : 0,
                     piano:modes.contains(.piano) ? mask(RemotePiano.signals) : 0,
                     pedals:modes.contains(.pedalboard) ? mask(RemotePedalboard.signals) : 0)
    }

    /// Frozen host-only labels. The bridge must authorize disclosure per invitation.
    func groupRemoteLabels(_ source:SensorSource) -> [RemoteMappingLabel] {
        remoteLabels[source] ?? []
    }

    /// Local consent preview; this is not a wire payload or permission.
    public func remoteLabelPreview(_ source:SensorSource) -> [String] {
        guard !retired,remoteModes[source] != nil else { return [] }
        return groupRemoteLabels(source).map {
            RemoteMappingProjection.signals[$0.signal].rawValue + " · " + $0.text
        }
    }

    /// Retire multiple remote owners atomically, never a local source or a
    /// replacement token. Avoid briefly restoring another departing control.
    public mutating func unbindRemoteBatch(_ tokens:[SensorSource:UUID],
                                           send:(PerformanceGroupCommand)->Bool) -> [PerformanceGroupDelivery.Report] {
        let sources = Set(tokens.compactMap { source,token in
            matchesRemoteBinding(source,token:token) ? source : nil
        })
        return reset(sources,send:send)
    }
    public var activeSessions: Int { delivery.sessionCount }
    public var pendingCleanup: Set<UUID> { delivery.pendingCleanup }
    public var retired: Bool { delivery.retired }

    /// Existing gamepad callers remain gamepad-only by default. Explicit
    /// local mode also accepts primary-contact Trackpad and Magic Mouse.
    /// Live groups must not silently send MIDI setup selectors or reset
    /// receiver gain to the legacy full-scale default. Archive and existing
    /// Builder behavior remain unchanged.
    public static func permitsLiveControl(_ route:SensorMapping) -> Bool {
        guard route.destination.kind == .controlChange else { return true }
        let number = route.destination.number
        guard ![0,6,32,38,96,97,98,99,100,101].contains(number) else { return false }
        return ![7,11].contains(number) || route.response?.release != nil
    }

    public static func supports(_ profile:PerformanceGroupProfile, allowSurfaces:Bool = false,
                                allowScalars:Bool = false, allowCamera:Bool = false,
                                allowRemote:Bool = false) -> Bool {
        let routes = profile.groups.flatMap { $0.patch.routes }
        let remote = Dictionary(grouping:routes.filter { $0.source.isGroupRemote },by:{ $0.source })
        guard remote.isEmpty || (allowRemote && remote.values.allSatisfy({ PerformanceGroupRemoteSurface.modes(for:$0) != nil })) else { return false }
        return profile.isValid && !routes.isEmpty && routes.allSatisfy {
            guard permitsLiveControl($0) else { return false }
            if GamepadFrame.sources.contains($0.source) { return GamepadFrame.permits($0) }
            if $0.source.isGroupRemote { return allowRemote }
            if allowCamera, $0.source == .camera {
                return [.x,.y,.gesture].contains($0.signal) &&
                    ContinuousResponse.isContinuous($0.destination)
            }
            if allowScalars, ($0.source == .lid && $0.signal == .angle) || ($0.source == .touchBar && $0.signal == .x) {
                return $0.destination.kind == .controlChange || $0.destination.kind == .pitchBend
            }
            return allowSurfaces && ($0.source == .trackpad || $0.source == .magicMouse) &&
                PhysicalPatchRuntime.supportedSignals.contains($0.signal)
        }
    }

    public init(profile: PerformanceGroupProfile, allowLayering: Bool = false,
                allowSurfaces: Bool = false, allowScalars: Bool = false, allowCamera: Bool = false,
                tuning:[UUID:PerformanceGroupTuningPlan.Specification] = [:], allowRemote:Bool = false,
                dynamicMPE:Bool = false) throws {
        guard Self.supports(profile,allowSurfaces:allowSurfaces,allowScalars:allowScalars,allowCamera:allowCamera,allowRemote:allowRemote) else {
            throw AdmissionError.unsupportedProfile
        }
        let routes = profile.groups.flatMap { $0.patch.routes }
        mapped = Dictionary(grouping:routes,by:{ $0.source }).mapValues { Set($0.map(\.signal)) }
        remoteModes = Dictionary(grouping:routes.filter { $0.source.isGroupRemote },by:{ $0.source })
            .compactMapValues { PerformanceGroupRemoteSurface.modes(for:$0) }
        // Only labels for mapped controls in this slot. Ambiguous labels on
        // layered inputs are omitted rather than choosing one group's text.
        var candidates:[SensorSource:[Int:Set<String>]] = [:]
        for group in profile.groups {
            for widget in group.patch.performanceLayout?.resolved(for:group.patch.routes) ?? [] {
                guard widget.source.isGroupRemote,RemoteMappingLabel.permits(widget.label),
                      let signal = RemoteMappingProjection.signals.firstIndex(of:widget.signal) else { continue }
                candidates[widget.source,default:[:]][signal,default:[]].insert(widget.label)
            }
        }
        remoteLabels = candidates.mapValues { values in
            values.keys.sorted().compactMap { signal in
                guard let labels = values[signal],labels.count == 1,let label = labels.first else { return nil }
                return RemoteMappingLabel(signal:signal,text:label)
            }
        }
        smoothed = Set(routes.filter { ($0.response?.smoothingMS ?? 0) > 0 }.map(\.source))
        if dynamicMPE {
            // Explicit local-only candidate; never infer from note count
            // or fall back to fixed/standard output after invalid setup.
            guard !tuning.isEmpty,!allowRemote else { throw AdmissionError.unsupportedProfile }
            delivery = DynamicLocalGroupOutput(engine:try .init(profile:profile,tuning:tuning,allowLayering:allowLayering))
        } else if tuning.isEmpty {
            delivery = try PerformanceGroupDelivery(profile:profile,allowLayering:allowLayering)
        } else {
            delivery = try PerformanceGroupTunedDelivery(profile:profile,tuning:tuning,allowLayering:allowLayering)
        }
    }

    /// Explicit one-shot setup for tuned sessions. Standard sessions need
    /// no setup. Never bind input before the selected output is ready.
    public mutating func prepare(send:(PerformanceGroupCommand)->Bool) -> Bool {
        delivery.prepare(send:send)
    }

    public mutating func bind(_ source: SensorSource, now: Double) throws -> UUID {
        guard !retired else { throw AdmissionError.retired }
        guard delivery.ready else { throw AdmissionError.setupRequired }
        guard mapped[source] != nil else { throw AdmissionError.invalidSlot }
        guard bindings[source] == nil else { throw AdmissionError.alreadyBound }
        guard now.isFinite, now >= clock else { throw AdmissionError.invalidTime }
        clock = now
        let token = UUID()
        var binding = Binding(token:token,boundAt:now)
        // Explicitly selected scalar adapters have no startup note gate.
        // They only admit continuous controls, never notes or pedals.
        binding.armed = source == .lid || source == .touchBar
        if remoteModes[source] != nil { binding.remoteLastReceipt = now }
        bindings[source] = binding
        return token
    }

    /// A complete snapshot, never a delta. No held button or trigger at
    /// startup or after a stall can sound until a neutral snapshot arrives.
    public mutating func receive(_ source: SensorSource, token: UUID,
                                 frame: GamepadFrame?, now: Double,
                                 send: (PerformanceGroupCommand) -> Bool) -> Result {
        guard !retired, GamepadFrame.sources.contains(source), bindings[source]?.token == token else {
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

    /// A primary-contact sample from the existing ordered surface mailbox.
    /// All nil means an observed lift. Partial or invalid samples are loss,
    /// not neutral evidence. Capture time controls the expiry deadline;
    /// processing time is the monotonic clock used by the shared router.
    public mutating func receiveSurface(_ source:SensorSource, token:UUID,
                                        x:Double?, y:Double?, size:Double?,
                                        hostTime:Double, now:Double,
                                        send:(PerformanceGroupCommand) -> Bool) -> Result {
        guard !retired, (source == .trackpad || source == .magicMouse),
              bindings[source]?.token == token else { return .init(status:.ignored,reports:[]) }
        guard now.isFinite, now >= clock else {
            return .init(status:.lost,reports:reset(Set(bindings.keys),send:send))
        }
        clock = now
        var reports = reset(staleSources(now:now),send:send)
        guard var binding = bindings[source] else { return .init(status:.ignored,reports:reports) }
        guard hostTime.isFinite, hostTime >= binding.boundAt, hostTime <= now,
              now-hostTime < Self.timeout,
              binding.lastSurfaceReceipt.map({ hostTime >= $0 }) ?? true else {
            reports += reset([source],send:send)
            return .init(status:.lost,reports:reports)
        }
        binding.lastSurfaceReceipt = hostTime
        bindings[source] = binding
        if x == nil && y == nil && size == nil {
            // Ordinary touch release ends this source lease, matching the
            // existing surface policy rather than the controller toggle lift.
            reports += reset([source],send:send)
            bindings[source]?.armed = true
            bindings[source]?.lastSeen = nil
            return .init(status:.ready,reports:reports)
        }
        guard let x, let y, let size,
              [x,y,size].allSatisfy({ $0.isFinite && (0...1).contains($0) }) else {
            reports += reset([source],send:send)
            return .init(status:.lost,reports:reports)
        }
        if let lease = binding.lease, !delivery.hasLease(lease) { binding.reset() }
        binding.lastSeen = hostTime
        guard binding.armed else {
            bindings[source] = binding
            return .init(status:.waitingForNeutral,reports:reports)
        }
        if binding.lease == nil {
            do { binding.lease = try delivery.connect(source,now:now) }
            catch {
                binding.reset()
                bindings[source] = binding
                return .init(status:.admissionRejected,reports:reports)
            }
        }
        let stride = UInt64(SensorSignal.allCases.count+1)
        guard let lease = binding.lease, binding.sequence < (UInt64.max-stride)/stride else {
            reports += reset([source],send:send)
            return .init(status:.lost,reports:reports)
        }
        binding.sequence += 1
        let values: [SensorSignal:Double] = [.x:x,.y:y,.contactSize:size,.contact:1]
        let filtered = values.filter { mapped[source]?.contains($0.key) == true }
        bindings[source] = binding
        reports.append(delivery.frame(lease:lease,sequence:binding.sequence,now:now,values:filtered,releasing:[],send:send))
        if !delivery.hasLease(lease) { bindings[source]?.reset() }
        return .init(status:.delivered,reports:reports)
    }

    /// Continuous local controls only. A Touch Bar release permits another
    /// gesture. Lid loss requires an explicit new binding. Capture-time
    /// expiry cannot be renewed by another source or by delayed processing.
    public mutating func receiveScalar(_ source:SensorSource, token:UUID,
                                       value:Double?, hostTime:Double, now:Double,
                                       send:(PerformanceGroupCommand) -> Bool) -> Result {
        guard !retired, (source == .lid || source == .touchBar),
              bindings[source]?.token == token else { return .init(status:.ignored,reports:[]) }
        guard now.isFinite, now >= clock else {
            return .init(status:.lost,reports:reset(Set(bindings.keys),send:send))
        }
        clock = now
        var reports = reset(staleSources(now:now),send:send)
        guard var binding = bindings[source] else { return .init(status:.ignored,reports:reports) }
        guard hostTime.isFinite, hostTime >= binding.boundAt, hostTime <= now, now-hostTime < Self.timeout,
              binding.lastSurfaceReceipt.map({ hostTime >= $0 }) ?? true else {
            reports += reset([source],send:send)
            return .init(status:.lost,reports:reports)
        }
        binding.lastSurfaceReceipt = hostTime
        bindings[source] = binding
        guard let value else {
            reports += reset([source],send:send)
            if source == .touchBar { bindings[source]?.armed = true }
            return .init(status:source == .touchBar ? .ready : .lost,reports:reports)
        }
        guard value.isFinite, (0...1).contains(value) else {
            reports += reset([source],send:send)
            return .init(status:.lost,reports:reports)
        }
        if let lease = binding.lease, !delivery.hasLease(lease) { binding.reset() }
        guard binding.armed else {
            bindings[source] = binding
            return .init(status:.waitingForNeutral,reports:reports)
        }
        binding.lastSeen = hostTime
        if binding.lease == nil {
            do { binding.lease = try delivery.connect(source,now:now) }
            catch {
                binding.reset()
                bindings[source] = binding
                return .init(status:.admissionRejected,reports:reports)
            }
        }
        let stride = UInt64(SensorSignal.allCases.count+1)
        guard let lease = binding.lease, binding.sequence < (UInt64.max-stride)/stride else {
            reports += reset([source],send:send)
            return .init(status:.lost,reports:reports)
        }
        binding.sequence += 1
        bindings[source] = binding
        reports.append(delivery.frame(lease:lease,sequence:binding.sequence,now:now,
            values:[source == .lid ? .angle : .x:value],releasing:[],send:send))
        if !delivery.hasLease(lease) { bindings[source]?.reset() }
        return .init(status:.delivered,reports:reports)
    }

    /// Single reliable hand, continuous controls only. Two consecutive
    /// fresh samples acquire tracking; loss clears camera ownership without
    /// affecting a different input. No images or camera access in this core.
    public mutating func receiveCamera(token:UUID, hand:AirHandSample?,
                                       hostTime:Double, now:Double,
                                       send:(PerformanceGroupCommand) -> Bool) -> Result {
        let source = SensorSource.camera
        guard !retired, bindings[source]?.token == token else {
            return .init(status:.ignored,reports:[])
        }
        guard now.isFinite, now >= clock else {
            return .init(status:.lost,reports:reset(Set(bindings.keys),send:send))
        }
        clock = now
        var reports = reset(staleSources(now:now),send:send)
        guard var binding = bindings[source] else { return .init(status:.ignored,reports:reports) }
        guard hostTime.isFinite, hostTime >= binding.boundAt, hostTime <= now, now-hostTime < Self.timeout,
              binding.lastSurfaceReceipt.map({ hostTime > $0 }) ?? true else {
            reports += reset([source],send:send)
            return .init(status:.lost,reports:reports)
        }
        binding.lastSurfaceReceipt = hostTime
        bindings[source] = binding
        guard let hand else {
            reports += reset([source],send:send)
            return .init(status:.lost,reports:reports)
        }
        guard let accepted = cameraTracking.accept(hand,at:hostTime,now:now) else {
            // First reliable frame is acquisition, not loss. Do not reset
            // the tracking gate here or acquisition could never complete.
            if let lease = binding.lease {
                reports.append(delivery.disconnect(lease,send:send))
                binding.reset()
            }
            binding.lastSeen = hostTime
            bindings[source] = binding
            return .init(status:.waitingForNeutral,reports:reports)
        }
        if let lease = binding.lease, !delivery.hasLease(lease) { binding.reset() }
        binding.armed = true
        binding.lastSeen = hostTime
        if binding.lease == nil {
            do { binding.lease = try delivery.connect(source,now:now) }
            catch {
                reports += reset([source],send:send)
                return .init(status:.admissionRejected,reports:reports)
            }
        }
        let stride = UInt64(SensorSignal.allCases.count+1)
        guard let lease = binding.lease, binding.sequence < (UInt64.max-stride)/stride else {
            reports += reset([source],send:send)
            return .init(status:.lost,reports:reports)
        }
        binding.sequence += 1
        bindings[source] = binding
        let values: [SensorSignal:Double] = [.x:accepted.x,.y:accepted.y,.gesture:accepted.aperture]
        reports.append(delivery.frame(lease:lease,sequence:binding.sequence,now:now,
            values:values.filter { mapped[source]?.contains($0.key) == true },releasing:[],send:send))
        if !delivery.hasLease(lease) {
            bindings[source]?.reset()
            cameraTracking.reset()
        }
        return .init(status:.delivered,reports:reports)
    }

    /// Only a trusted, authenticated host adapter may bind a remote slot and
    /// supply its token and monotonic receipt. No listener is opened here.
    /// One selected surface per slot; an explicit neutral snapshot arms it.
    /// Idle heartbeats never renew a held note, pad or control.
    public mutating func receiveRemote(_ source:SensorSource,token:UUID,bytes:Data,
                                       hostTime:Double,now:Double,
                                       send:(PerformanceGroupCommand)->Bool) -> Result {
        // Unauthenticated callers still cannot trigger wire decoding.
        guard !retired,remoteModes[source] != nil,bindings[source]?.token == token else {
            return .init(status:.ignored,reports:[])
        }
        return receiveRemoteValidated(source,token:token,validated:try? .init(bytes:bytes),
                                      hostTime:hostTime,now:now,send:send)
    }

    /// Internal shared path for the bridge's already strictly parsed frame.
    /// Authentication, receipt freshness, rate and sequence fences remain
    /// authoritative here; a caller cannot construct a proof from a raw frame.
    mutating func receiveRemoteValidated(_ source:SensorSource,token:UUID,validated:ValidatedGroupRemoteFrame?,
                                         hostTime:Double,now:Double,
                                         send:(PerformanceGroupCommand)->Bool) -> Result {
        guard !retired, let modes = remoteModes[source], bindings[source]?.token == token else {
            return .init(status:.ignored,reports:[])
        }
        guard now.isFinite, now >= clock else {
            return .init(status:.lost,reports:reset(Set(bindings.keys),send:send))
        }
        clock = now
        var reports = reset(staleSources(now:now),send:send)
        guard var binding = bindings[source] else { return .init(status:.lost,reports:reports) }
        guard binding.remoteLastReceipt.map({ hostTime >= $0 }) ?? false,
              let frame = binding.remoteFence.accept(validated,receipt:hostTime,now:now) else {
            reports += reset([source],send:send)
            return .init(status:.lost,reports:reports)
        }
        binding.remoteLastReceipt = hostTime
        if frame.kind == .heartbeat || frame.kind == .capabilities || frame.kind == .mapping || frame.kind == .mappingLabels {
            guard binding.lease == nil else {
                reports += reset([source],send:send)
                return .init(status:.lost,reports:reports)
            }
            bindings[source] = binding
            return .init(status:binding.armed ? .ready : .waitingForNeutral,reports:reports)
        }
        guard let family = PerformanceGroupRemoteSurface.family(for:frame),modes.contains(family) else {
            reports += reset([source],send:send)
            return .init(status:.lost,reports:reports)
        }
        let signals = (mapped[source] ?? []).intersection(family.signals)
        guard let values = family.snapshot(frame,mapped:signals) else {
            reports += reset([source],send:send)
            return .init(status:.lost,reports:reports)
        }
        if let lease = binding.lease, !delivery.hasLease(lease) {
            reports += reset([source],send:send)
            return .init(status:.lost,reports:reports)
        }
        if !binding.armed {
            if values.isEmpty { binding.remoteNeutral.insert(family) }
            else { binding.remoteNeutral.remove(family) }
            binding.armed = binding.remoteNeutral == modes
            bindings[source] = binding
            return .init(status:binding.armed ? .ready : .waitingForNeutral,reports:reports)
        }
        if values.isEmpty { binding.remoteActive.removeValue(forKey:family) }
        else { binding.remoteActive[family] = hostTime }
        if binding.remoteActive.isEmpty {
            if let lease = binding.lease { reports.append(delivery.disconnect(lease,send:send)) }
            binding.reset()
            binding.armed = true
            bindings[source] = binding
            return .init(status:.ready,reports:reports)
        }
        // Only this family's signals are updated/released. Other families
        // retain ownership, not synthetic refreshes or smoothing samples.
        if binding.lease == nil {
            do { binding.lease = try delivery.connect(source,now:now) }
            catch {
                reports += reset([source],send:send)
                return .init(status:.admissionRejected,reports:reports)
            }
        }
        let stride = UInt64(SensorSignal.allCases.count+1)
        guard let lease = binding.lease, binding.sequence < (UInt64.max-stride)/stride else {
            reports += reset([source],send:send)
            return .init(status:.lost,reports:reports)
        }
        binding.sequence += 1
        bindings[source] = binding
        reports.append(delivery.frame(lease:lease,sequence:binding.sequence,now:now,
            values:values,releasing:signals.subtracting(values.keys),send:send))
        if !delivery.hasLease(lease) {
            reports += reset([source],send:send)
            return .init(status:.lost,reports:reports)
        }
        return .init(status:.delivered,reports:reports)
    }

    /// Host must call at the existing watchdog cadence. No change to the
    /// physical deadline, and no timeout renewal by unrelated controllers.
    public mutating func expire(now: Double, send: (PerformanceGroupCommand) -> Bool) -> [PerformanceGroupDelivery.Report] {
        expire(now:now,removingRemote:[:],send:send)
    }

    /// Combine known disconnects with watchdog expiry before reconciling
    /// shared targets; never briefly restore another departing owner.
    public mutating func expire(now:Double,removingRemote tokens:[SensorSource:UUID],
                                send:(PerformanceGroupCommand)->Bool) -> [PerformanceGroupDelivery.Report] {
        guard !retired else { return [] }
        guard now.isFinite, now >= clock else { return reset(Set(bindings.keys),send:send) }
        clock = now
        let departing = Set(tokens.compactMap { source,token in
            matchesRemoteBinding(source,token:token) ? source : nil
        })
        return reset(staleSources(now:now).union(departing),send:send)
    }

    /// Actual unplug or deliberate detach retires the binding token; a new
    /// physical device must be explicitly bound, never auto-substituted.
    public mutating func unbind(_ source: SensorSource, token: UUID,
                                send: (PerformanceGroupCommand) -> Bool) -> [PerformanceGroupDelivery.Report] {
        unbindBatch([source:token],send:send)
    }

    /// Explicit simultaneous retirement. Match every token before releasing
    /// any owner so another departing source is never restored temporarily.
    public mutating func unbindBatch(_ tokens:[SensorSource:UUID],
                                     send:(PerformanceGroupCommand)->Bool) -> [PerformanceGroupDelivery.Report] {
        let sources = Set(tokens.compactMap { source,token in
            bindings[source]?.token == token ? source : nil
        })
        let reports = reset(sources,send:send)
        for source in sources { bindings.removeValue(forKey:source) }
        return reports
    }

    public mutating func stopGroup(_ id: UUID, send: (PerformanceGroupCommand) -> Bool) -> PerformanceGroupDelivery.Report {
        delivery.stopGroup(id,send:send)
    }
    public mutating func panic(send: (PerformanceGroupCommand) -> Bool) -> PerformanceGroupDelivery.Report {
        bindings.removeAll()
        cameraTracking.reset()
        return delivery.panic(send:send)
    }
    public mutating func retryCleanup(_ id: UUID, send: (PerformanceGroupCommand) -> Bool) -> PerformanceGroupDelivery.Report {
        delivery.retryCleanupReport(id,send:send)
    }

    private func staleSources(now: Double) -> Set<SensorSource> {
        Set(bindings.compactMap { source,binding in
            if let last = binding.lastSeen, now-last >= Self.timeout { return source }
            if binding.remoteActive.values.contains(where:{ now-$0 >= Self.timeout }) { return source }
            if let last = binding.remoteLastReceipt, now-last >= 2 { return source }
            return nil
        })
    }

    private mutating func reset(_ sources: Set<SensorSource>,
                                send: (PerformanceGroupCommand) -> Bool) -> [PerformanceGroupDelivery.Report] {
        if sources.contains(.camera) { cameraTracking.reset() }
        var leases: Set<UUID> = []
        for source in sources {
            guard var binding = bindings[source] else { continue }
            if let lease = binding.lease { leases.insert(lease) }
            // Remote loss retires the authenticated slot token. A late packet
            // may not rearm it; the transport must pair/bind explicitly again.
            if remoteModes[source] != nil { bindings.removeValue(forKey:source) }
            else {
                binding.reset()
                bindings[source] = binding
            }
        }
        guard !leases.isEmpty else { return [] }
        return [delivery.disconnectBatch(leases,send:send)]
    }
}
