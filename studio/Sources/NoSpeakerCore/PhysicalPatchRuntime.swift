import Foundation

/// One explicitly selected physical surface per source kind. A primary
/// contact drives the patch, not a synthetic pressure or finger-count sensor.
public struct PhysicalPatchRuntime: Sendable {
    public static let supportedSignals: Set<SensorSignal> = [.x, .y, .contact, .contactSize]
    public static let timeout = 0.35
    private var router = SensorRouter()
    private var airDual = AirDualHandPerformance()
    private var airDualEnabled = false
    private var airHelperEnabled = false
    private var airActiveSlot: Int?
    private var airStrum: AirStrumPerformance?
    private var cameraHands = AirHandsHelper()
    private var cameraHandsEnabled = false
    private var supported: Set<SensorSource> = []
    private var hybridSource: SensorSource?
    public private(set) var hybridInputs: [PatchSimulation.Input] = []
    private var hybridSession: UUID?
    private var hybridReceipt: Double?
    private var sessions: [SensorSource: UUID] = [:]
    private var seen: [SensorSource: Double] = [:]
    private var gamepadArmed:Set<SensorSource> = []
    private var gamepadMappedSignals: [SensorSource:[SensorSignal]] = [:]
    private var gamepadSmoothedSources: Set<SensorSource> = []
    private var lastGamepadActive: [SensorSource:[SensorSignal:Double]] = [:]
    public private(set) var gamepadSnapshotMetrics = GamepadSnapshotMetrics()

    public mutating func resetGamepadSnapshotMetrics() {
        gamepadSnapshotMetrics = GamepadSnapshotMetrics()
    }
    public var reservedGamepadSessions:Int { supported.intersection(GamepadFrame.sources).count }
    public var remoteSessionLimit:Int { Self.maximumRemoteSessions-reservedGamepadSessions }
    private var sequence: UInt64 = 0
    private var motionSources: Set<SensorSource> = []
    private var touchSources: Set<SensorSource> = []
    private var inertialSignals: [SensorSource: Set<SensorSignal>] = [:]
    private var drumMasks: [SensorSource: Int] = [:]
    private var pianoMasks: [SensorSource: Int] = [:]
    private var pedalMasks: [SensorSource: Int] = [:]
    private var strikeSettings: [SensorSource: AirStrikeDetector.Settings] = [:]
    private static let strikeDuration = 0.06
    private var remoteEnabled = false
    private var pairing = RemotePairingGate()
    private var mappingProjections: [SensorSource:RemoteMappingProjection] = [:]
    private var remotePeers: [UUID: RemoteTouchPeer] = [:]
    public static let maximumRemotePeers = 4
    // One session for each supported local source: trackpad, mouse, lid, Touch Bar, camera.
    public static let reservedLocalSessions = 5
    public static let maximumRemoteSessions = SensorRouter.maxSessions - reservedLocalSessions
    public var reservedRemoteSessions: Int {
        remotePeers.values.reduce(0) { $0 + remoteSessionCost($1.source) }
    }
    private func remoteSessionCost(_ source: SensorSource) -> Int {
        var cost = inertialSignals[source]?.count ?? 0
        if touchSources.contains(source) { cost += 1 }
        if motionSources.contains(source) { cost += 1 }
        if (drumMasks[source] ?? 0) != 0 { cost += 1 }
        if (pianoMasks[source] ?? 0) != 0 { cost += 1 }
        if (pedalMasks[source] ?? 0) != 0 { cost += 1 }
        return cost
    }
    public var remotePeerIDs: Set<UUID> { Set(remotePeers.keys) }

    public init() {}
    public var activeSources: Set<SensorSource> { Set(sessions.keys) }
    public var airSelectedSlot: Int? { airDual.trackingReady ? airDual.selectedSlot : nil }
    public var airSoundingSlot: Int? {
        if let airStrum, !airStrum.hasActivePulses { return nil }
        return airDual.soundingSlot
    }
    // Internal test observation of real router allocation, not a wire metric.
    var activeRouterSessionCount: Int { router.sessionCount }

    public static func supports(_ patch: InstrumentPatch, allowRemote: Bool = false) -> Bool {
        patch.isValid && !patch.routes.isEmpty && patch.routes.allSatisfy {
            switch $0.source {
            case .trackpad, .magicMouse: return supportedSignals.contains($0.signal)
            case .gamepad1,.gamepad2: return GamepadFrame.permits($0)
            case .lid: return $0.signal == .angle
            case .touchBar: return $0.signal == .x
            case .camera: return [.x,.y,.gesture,.contact].contains($0.signal) || AirDualHandPerformance.signals.contains($0.signal) || AirStrumPerformance.isStringSignal($0.signal) || AirHandsHelper.allSignals.contains($0.signal)
            case .phone, .tablet:
                guard allowRemote else { return false }
                if [.x,.y,.contact].contains($0.signal) { return true }
                if $0.signal == .airStrike { return $0.destination.kind == .note }
                if RemoteDrumPads.signals.contains($0.signal) { return RemoteDrumPads.permits($0) }
                if RemotePiano.signals.contains($0.signal) { return RemotePiano.permits($0) }
                if RemotePedalboard.signals.contains($0.signal) { return RemotePedalboard.permits($0) }
                return [.tiltYaw,.tiltPitch,.tiltRoll,.accelerationMagnitude,.rotationMagnitude].contains($0.signal) &&
                    ($0.destination.kind == .controlChange || $0.destination.kind == .pitchBend)
            default: return false
            }
        }
    }

    /// One explicitly substituted source. Never simulate a live camera or a
    /// paired network stream, and never enlarge the local reservation.
    public static func supportsHybrid(_ patch:InstrumentPatch, synthetic:SensorSource, allowRemote:Bool = false) -> Bool {
        let sources = Set(patch.routes.map(\.source))
        let remote = sources.intersection([.phone,.tablet])
        guard patch.isValid,[SensorSource.trackpad,.magicMouse,.touchBar,.lid,.external,.camera].contains(synthetic),
              sources.subtracting(remote).subtracting(GamepadFrame.sources).count <= reservedLocalSessions,
              allowRemote == !remote.isEmpty else { return false }
        let syntheticRoutes = patch.routes.filter { $0.source == synthetic }
        let simple:Set<SensorSignal> = [.x,.y,.contact,.contactSize,.pressure,.angle,.speed,.gesture,.expression]
        guard !syntheticRoutes.isEmpty else { return false }
        if synthetic == .camera {
            guard AirDualHandPerformance.usesDualCamera(patch.routes) || AirHandsHelper.uses(patch.routes),
                  supports(.init(routes:syntheticRoutes)) else { return false }
        } else if !syntheticRoutes.allSatisfy({ simple.contains($0.signal) }) { return false }
        let native = InstrumentPatch(name:patch.name,routes:patch.routes.filter { $0.source != synthetic })
        return supports(native,allowRemote:allowRemote)
    }

    public mutating func configure(_ patch: InstrumentPatch, allowRemote: Bool = false,
                                   synthetic:SensorSource? = nil) throws {
        guard sessions.isEmpty, remotePeers.isEmpty, hybridSession == nil,
              synthetic.map({ Self.supportsHybrid(patch,synthetic:$0,allowRemote:allowRemote) }) ?? Self.supports(patch, allowRemote:allowRemote)
              else { throw SensorRouterError.invalidMappings }
        var projections: [SensorSource:RemoteMappingProjection] = [:]
        if allowRemote {
            for source in [SensorSource.phone,.tablet] where patch.routes.contains(where: { $0.source == source }) {
                projections[source] = try RemoteMappingProjection(patch:patch,source:source,synthetic:synthetic)
            }
        }
        try router.configure(patch.routes)
        airDual = AirDualHandPerformance()
        cameraHands.reset()
        cameraHandsEnabled = AirHandsHelper.uses(patch.routes)
        airActiveSlot = nil
        airDualEnabled = AirDualHandPerformance.usesDualCamera(patch.routes)
        airStrum = AirStrumPerformance(routes:patch.routes)
        airHelperEnabled = airDualEnabled && AirDualHandPerformance.hasHelperRoutes(patch.routes)
        mappingProjections = projections
        hybridSource = synthetic
        hybridInputs = Array(Set(patch.routes.filter { $0.source == synthetic && synthetic != .camera }.map { PatchSimulation.Input(source:$0.source,signal:$0.signal) })).sorted { $0.id < $1.id }
        hybridReceipt = nil
        supported = Set(patch.routes.map(\.source)).subtracting(synthetic.map { [$0] } ?? [])
        touchSources = Set(patch.routes.filter { [.x,.y,.contact].contains($0.signal) }.map(\.source))
        motionSources = Set(patch.routes.filter { [.tiltYaw,.tiltPitch,.tiltRoll].contains($0.signal) }.map(\.source))
        drumMasks = [:]
        pianoMasks = [:]
        pedalMasks = [:]
        for route in patch.routes {
            if let index = RemotePedalboard.signals.firstIndex(of: route.signal) { pedalMasks[route.source, default: 0] |= 1 << index }
            if let index = RemotePiano.signals.firstIndex(of: route.signal) { pianoMasks[route.source, default: 0] |= 1 << index }
            if let index = RemoteDrumPads.signals.firstIndex(of: route.signal) { drumMasks[route.source, default: 0] |= 1 << index }
        }
        inertialSignals = [:]
        strikeSettings = AirDrumSensitivity.settings(for: patch.routes) ?? [:]
        for source in strikeSettings.keys { inertialSignals[source, default: []].insert(.accelerationMagnitude) }
        for route in patch.routes where [.accelerationMagnitude,.rotationMagnitude].contains(route.signal) {
            inertialSignals[route.source, default: []].insert(route.signal)
        }
        remoteEnabled = allowRemote
        pairing.clear()
        seen = [:]
        gamepadArmed = []
        gamepadMappedSignals = [:]
        gamepadSmoothedSources = []
        lastGamepadActive = [:]
        resetGamepadSnapshotMetrics()
        for source in supported.intersection(GamepadFrame.sources) {
            let routes = patch.routes.filter { $0.source == source }
            let signals = Set(routes.map(\.signal))
            gamepadMappedSignals[source] = GamepadFrame.signals.filter { signals.contains($0) }
            if routes.contains(where:{ ($0.response?.smoothingMS ?? 0) > 0 }) {
                gamepadSmoothedSources.insert(source)
            }
        }
        sequence = 0
    }

    /// UI-originated synthetic values share the physical router and ledger,
    /// never the hardware adapter. A stale lease requires a fresh user action.
    public mutating func sendHybrid(_ input:PatchSimulation.Input,value:Double,now:Double) -> [SensorCommand] {
        guard input.source == hybridSource,hybridInputs.contains(input),now.isFinite,now >= 0,
              value.isFinite,(0...1).contains(value) else { return [] }
        if let last = hybridReceipt, now < last { return releaseHybridSource() }
        var commands = expireHybrid(now:now)
        if hybridSession == nil { hybridSession = try? router.connect(input.source,now:now) }
        guard let id = hybridSession else { return commands }
        hybridReceipt = now
        sequence &+= 1
        commands += router.ingest(.init(session:id,signal:input.signal,value:value,sequence:sequence,timestamp:now),now:now)
        return commands
    }
    public mutating func releaseHybrid(_ input:PatchSimulation.Input) -> [SensorCommand] {
        guard hybridInputs.contains(input),let id = hybridSession else { return [] }
        return router.releaseSignal(session:id,signal:input.signal)
    }
    public mutating func releaseHybridSource() -> [SensorCommand] {
        if hybridSource == .camera { return releaseCamera() }
        guard let id = hybridSession else { return [] }
        hybridSession = nil; hybridReceipt = nil
        return router.disconnect(id)
    }
    /// Heartbeats only renew existing ownership; never recreate notes.
    public mutating func refreshHybrid(now:Double) -> [SensorCommand] {
        let commands = expireHybrid(now:now)
        if let id = hybridSession {
            hybridReceipt = now
            router.heartbeat(id,now:now)
        }
        return commands
    }
    private mutating func expireHybrid(now:Double) -> [SensorCommand] {
        guard let last = hybridReceipt else { return [] }
        guard now.isFinite,now >= last,now-last < Self.timeout else { return releaseHybridSource() }
        return []
    }

    /// hostTime is local receipt time, not the undocumented driver timestamp.
    /// An empty frame or invalid sample releases the entire physical source.
    public mutating func receive(source: SensorSource, x: Double?, y: Double?, size: Double?,
                                 hostTime: Double, now: Double) -> [SensorCommand] {
        guard (source == .trackpad || source == .magicMouse), supported.contains(source), hostTime.isFinite, now.isFinite,
              hostTime >= 0, hostTime <= now, now - hostTime < Self.timeout,
              hostTime >= (seen[source] ?? 0) else { return [] }
        seen[source] = hostTime
        guard let x, let y, let size, [x,y,size].allSatisfy({ $0.isFinite && (0...1).contains($0) })
        else { return disconnect(source) }
        if sessions[source] == nil {
            sessions[source] = try? router.connect(source, now: hostTime)
        }
        guard let session = sessions[source] else { return [] }
        var result: [SensorCommand] = []
        // Position/control updates precede contact-gated Note On.
        for (signal, value): (SensorSignal, Double) in [(.x,x),(.y,y),(.contactSize,size),(.contact,1)] {
            sequence &+= 1
            result += router.ingest(.init(session: session, signal: signal, value: value,
                                          sequence: sequence, timestamp: hostTime), now: hostTime)
        }
        return result
    }

    /// Lid degrees are normalized over the documented valid sensor range.
    /// Mapping calibration then selects the comfortable musical sweep.
    public static func normalizedLid(_ degrees: Double) -> Double? {
        guard degrees.isFinite, (5...175).contains(degrees) else { return nil }
        return (degrees - 5) / 170
    }

    /// The adapter supplies a full snapshot of a previously bound controller.
    /// Neutral frame required before first play or after loss/stall.
    public mutating func receiveGamepad(source:SensorSource,frame:GamepadFrame?,now:Double) -> [SensorCommand] {
        guard GamepadFrame.sources.contains(source),supported.contains(source) else { return [] }
        guard let frame,now.isFinite,now >= 0 else { return releaseGamepad(source) }
        if let last = seen[source],now < last || now-last >= Self.timeout {
            return releaseGamepad(source)
        }
        seen[source] = now
        if !gamepadArmed.contains(source) {
            if frame.active.isEmpty { gamepadArmed.insert(source) }
            return []
        }
        if sessions[source] == nil {
            guard !frame.active.isEmpty else { return [] }
            sessions[source] = try? router.connect(source,now:now)
        }
        guard let session = sessions[source] else { return [] }
        router.heartbeat(session,now:now)
        // Duplicate callback/poll snapshots must still renew the lease.
        // Smoothing is time-based and must continue receiving held samples.
        if !gamepadSmoothedSources.contains(source), lastGamepadActive[source] == frame.active {
            gamepadSnapshotMetrics.record(skipped:true,events:0)
            return []
        }
        lastGamepadActive[source] = frame.active
        var events:[SensorEvent] = []
        var releasing: Set<SensorSignal> = []
        for signal in gamepadMappedSignals[source] ?? [] {
            guard let value = frame.active[signal] else {
                releasing.insert(signal)
                continue
            }
            sequence &+= 1
            events.append(.init(session:session,signal:signal,value:value,sequence:sequence,timestamp:now))
        }
        gamepadSnapshotMetrics.record(skipped:false,events:events.count)
        return router.ingestFrame(session:session,releasing:releasing,events:events,now:now)
    }
    public mutating func releaseGamepad(_ source:SensorSource) -> [SensorCommand] {
        guard GamepadFrame.sources.contains(source) else { return [] }
        gamepadArmed.remove(source); seen.removeValue(forKey:source)
        lastGamepadActive.removeValue(forKey:source)
        return disconnect(source)
    }

    /// Scalar adapters share the same router and ownership as touch surfaces.
    /// Nil is a release/lost sample, not a synthetic input of zero.
    public mutating func receiveScalar(source: SensorSource, value: Double?,
                                       hostTime: Double, now: Double) -> [SensorCommand] {
        guard source == .lid || source == .touchBar, supported.contains(source),
              hostTime.isFinite, now.isFinite, hostTime >= 0, hostTime <= now,
              now - hostTime < Self.timeout, hostTime >= (seen[source] ?? 0) else { return [] }
        seen[source] = hostTime
        guard let value, value.isFinite, (0...1).contains(value) else { return disconnect(source) }
        if sessions[source] == nil { sessions[source] = try? router.connect(source, now: hostTime) }
        guard let session = sessions[source] else { return [] }
        sequence &+= 1
        return router.ingest(.init(session: session, signal: source == .lid ? .angle : .x,
                                   value: value, sequence: sequence, timestamp: hostTime), now: hostTime)
    }

    /// Camera frame identity is not tracked across hands. The adapter
    /// rejects multiple/low-confidence hands; nil releases this source.
    public mutating func receiveHand(_ hand: AirHandSample?, hostTime: Double, now: Double) -> [SensorCommand] {
        let source = SensorSource.camera
        guard !airDualEnabled, !cameraHandsEnabled, supported.contains(source), hostTime.isFinite, now.isFinite,
              hostTime >= 0, hostTime <= now, now - hostTime < Self.timeout,
              hostTime >= (seen[source] ?? 0) else { return [] }
        seen[source] = hostTime
        guard let hand else { return disconnect(source) }
        if sessions[source] == nil { sessions[source] = try? router.connect(source, now: hostTime) }
        guard let session = sessions[source] else { return [] }
        var result: [SensorCommand] = []
        for (signal, value): (SensorSignal, Double) in [(.x,hand.x),(.y,hand.y),(.gesture,hand.aperture),(.contact,1)] {
            sequence &+= 1
            result += router.ingest(.init(session: session, signal: signal, value: value,
                                          sequence: sequence, timestamp: hostTime), now: hostTime)
        }
        return result
    }

    public mutating func receiveHelperHands(left:AirHandSample?,right:AirHandSample?,
                                            hostTime:Double,now:Double,synthetic:Bool = false) -> [SensorCommand] {
        guard synthetic == (hybridSource == .camera), cameraHandsEnabled, !airDualEnabled else { return [] }
        guard hostTime.isFinite, now.isFinite, hostTime >= 0, now >= hostTime,
              now-hostTime < 0.25, hostTime > (seen[.camera] ?? -1) else { return releaseCamera() }
        if let last = seen[.camera], hostTime-last >= 0.25 {
            let release = releaseCamera()
            seen[.camera] = hostTime
            return release
        }
        seen[.camera] = hostTime
        if left == nil && right == nil { return releaseCamera() }
        if sessions[.camera] == nil { sessions[.camera] = try? router.connect(.camera,now:hostTime) }
        guard let session = sessions[.camera] else { cameraHands.reset(); return [] }
        return cameraHands.receive(left:left,right:right,time:hostTime,now:now,
                                   session:session,router:&router,sequence:&sequence)
    }

    /// Dual-hand frames use the same session, router and output ledger as
    /// single-hand camera input. No additional reserved session is consumed.
    /// Single timestamp and single reserved session for both camera roles.
    public mutating func receiveCombinedHands(count:Int?,confidence:Double,left:AirHandSample?,
                                              right:AirHandSample?,swapRoles:Bool,
                                              hostTime:Double,now:Double,synthetic:Bool = false) -> [SensorCommand] {
        guard synthetic == (hybridSource == .camera), airDualEnabled, cameraHandsEnabled else { return [] }
        guard hostTime.isFinite,now.isFinite,hostTime >= 0,now >= hostTime,now-hostTime < 0.25,
              seen[.camera].map({ hostTime > $0 }) ?? true else { return releaseCamera() }
        if let last = seen[.camera], hostTime-last >= 0.25 {
            let commands = releaseCamera()
            seen[.camera] = hostTime
            return commands
        }
        seen[.camera] = hostTime
        guard left != nil || right != nil else { return releaseCamera() }
        if sessions[.camera] == nil { sessions[.camera] = try? router.connect(.camera,now:hostTime) }
        guard let session = sessions[.camera] else { return releaseCamera() }
        let helper = swapRoles ? left : right
        let chord = swapRoles ? right : left
        let slot = airDual.receive(count:chord == nil ? nil : count,confidence:confidence,
                                   helper:helper,time:hostTime,now:now)
        var commands = cameraHands.receive(left:left,right:right,time:hostTime,now:now,
                                           session:session,router:&router,sequence:&sequence)
        guard let helper, slot != nil || (airHelperEnabled && airDual.trackingReady) else {
            commands += AirHandsHelper.releaseInstrument(session:session,router:&router)
            airStrum?.reset()
            airActiveSlot = nil
            return commands
        }
        commands += AirDualHandPerformance.route(slot:airStrum == nil ? slot : nil,
                                                 previous:airStrum == nil ? airActiveSlot : nil,
                                                 helper:helper,session:session,time:hostTime,router:&router,sequence:&sequence)
        if airStrum != nil {
            commands += airStrum!.update(slot:slot,position:helper.x,time:hostTime,now:now,
                                         session:session,router:&router,sequence:&sequence)
        }
        airActiveSlot = slot
        return commands
    }

    public mutating func receiveDualHand(count: Int?, confidence: Double,
                                         helper: AirHandSample?, hostTime: Double,
                                         now: Double,synthetic:Bool = false) -> [SensorCommand] {
        guard synthetic == (hybridSource == .camera), airDualEnabled, !cameraHandsEnabled else { return [] }
        guard hostTime.isFinite, now.isFinite, hostTime >= 0, hostTime <= now,
              now - hostTime < 0.25, hostTime > (seen[.camera] ?? -1)
        else { return releaseCamera() }
        let slot = airDual.receive(count: count, confidence: confidence, helper: helper,
                                   time: hostTime, now: now)
        // Selected hands may drive continuous controls without sounding a chord.
        guard let helper, slot != nil || (airHelperEnabled && airDual.trackingReady) else {
            seen[.camera] = hostTime
            airActiveSlot = nil
            airStrum?.reset()
            return disconnect(.camera)
        }
        seen[.camera] = hostTime
        if sessions[.camera] == nil { sessions[.camera] = try? router.connect(.camera, now: hostTime) }
        guard let session = sessions[.camera] else { airDual.reset(); airActiveSlot = nil; return [] }
        var commands = AirDualHandPerformance.route(slot: airStrum == nil ? slot : nil, previous: airStrum == nil ? airActiveSlot : nil, helper: helper,
                                                    session: session, time: hostTime, router: &router,
                                                    sequence: &sequence)
        if airStrum != nil {
            commands += airStrum!.update(slot:slot,position:helper.x,time:hostTime,now:now,session:session,router:&router,sequence:&sequence)
        }
        airActiveSlot = slot
        return commands
    }

    /// Host-only API: a future transport must bind returned IDs to connections.
    public mutating func issueRemotePairing(secret: Data, source: SensorSource, now: Double, mappingDetails: Bool = false, mappingLabels: Bool = false) throws {
        guard remoteEnabled, supported.contains(source), source == .phone || source == .tablet
        else { throw RemoteTouchError.unavailable }
        try pairing.issue(secret: secret, source: source, now: now, mappingDetails: mappingDetails, mappingLabels: mappingLabels)
    }

    public mutating func admitRemote(secret: Data, now: Double) throws -> UUID {
        guard remoteEnabled else { throw RemoteTouchError.unavailable }
        // A valid one-time invitation is consumed even when capacity is full.
        // A wrong secret does not consume a still-valid invitation.
        let invitation = try pairing.consumeWithConsent(secret:secret,now:now)
        guard remotePeers.count < Self.maximumRemotePeers else { throw RemoteTouchError.capacity }
        let source = invitation.source
        guard supported.contains(source) else { throw RemoteTouchError.unavailable }
        let cost = remoteSessionCost(source)
        // Reserve the full advertised source capability before admitting a peer.
        // Reservations persist until peer removal, not merely stream release.
        guard cost > 0 else { throw RemoteTouchError.unavailable }
        guard reservedRemoteSessions + cost <= remoteSessionLimit else { throw RemoteTouchError.capacity }
        let id = UUID()
        remotePeers[id] = RemoteTouchPeer(source: source, now: now, mappingDetails: invitation.mappingDetails, mappingLabels: invitation.mappingLabels)
        return id
    }

    /// Available only for an already admitted peer; never exposes secrets,
    /// local routes, destination IDs, patch name or arbitrary host metadata.
    public func remoteCapabilities(_ id: UUID) -> RemoteCapabilities? {
        guard remoteEnabled, let peer = remotePeers[id] else { return nil }
        let source = peer.source
        return .init(touch: touchSources.contains(source), tilt: motionSources.contains(source),
                     acceleration: inertialSignals[source]?.contains(.accelerationMagnitude) == true,
                     rotation: inertialSignals[source]?.contains(.rotationMagnitude) == true,
                     airDrums: strikeSettings[source] != nil, drums: drumMasks[source] ?? 0,
                     piano: pianoMasks[source] ?? 0, pedals: pedalMasks[source] ?? 0)
    }

    // Internal projection API. The wire path must first accept the request in receiveRemote.
    func remoteMappingPage(_ id: UUID, page: Int, sequence: UInt64) throws -> RemoteMappingPage {
        guard remoteEnabled, let peer = remotePeers[id], peer.isIdle,
              let projection = mappingProjections[peer.source] else { throw RemoteTouchError.unavailable }
        return try projection.page(page,sequence:sequence,detail:peer.mappingDetails)
    }

    // Wire dispatch must first accept the request in receiveRemote.
    func remoteMappingLabelPage(_ id: UUID, page: Int, sequence: UInt64) throws -> RemoteMappingLabelPage {
        guard remoteEnabled, let peer = remotePeers[id], peer.isIdle, peer.mappingDetails,
              peer.mappingComplete, !peer.performanceStarted,
              let projection = mappingProjections[peer.source] else { throw RemoteTouchError.unavailable }
        return try projection.labelPage(page,sequence:sequence,allowed:peer.mappingLabels)
    }

    public mutating func receiveRemote(_ id: UUID, bytes: Data, now: Double) -> RemoteTouchResult {
        guard var peer = remotePeers[id], remoteEnabled else { return .close([]) }
        guard let frame = try? RemoteTouchFrame.read(bytes), peer.accept(frame, now: now)
        else { return .close(revokeRemote(id)) }
        // Legacy clients may omit v8 entirely. Once metadata begins, only the
        // next mapping page is accepted until that snapshot is complete.
        if peer.mappingStarted != nil && !peer.mappingComplete && frame.kind != .mapping {
            return .close(revokeRemote(id))
        }
        if peer.labelStarted && !peer.labelComplete && frame.kind != .mappingLabels {
            return .close(revokeRemote(id))
        }
        if frame.kind != .heartbeat && frame.kind != .capabilities && frame.kind != .mapping && frame.kind != .mappingLabels {
            peer.performanceStarted = true
        }
        switch frame.kind {
        case .heartbeat, .capabilities:
            if frame.kind == .capabilities { peer.capabilitiesSeen = true }
            remotePeers[id] = peer
            return .accepted([])
        case .mapping:
            guard peer.capabilitiesSeen, !peer.performanceStarted, !peer.mappingComplete,
                  let index = frame.page, index == peer.mappingNext,
                  peer.mappingLast.map({ now-$0 >= 0.05-1e-9 }) ?? true,
                  let page = try? remoteMappingPage(id,page:index,sequence:frame.sequence),
                  (try? page.encoded()) != nil else { return .close(revokeRemote(id)) }
            if peer.mappingStarted == nil { peer.mappingStarted = now }
            peer.mappingLast = now
            peer.mappingNext += 1
            peer.mappingComplete = peer.mappingNext == page.pages
            remotePeers[id] = peer
            return .accepted([])
        case .mappingLabels:
            guard peer.mappingComplete, peer.mappingDetails, !peer.performanceStarted, !peer.labelComplete,
                  let started = peer.mappingStarted, now-started < 10,
                  let index = frame.page, index == peer.labelNext,
                  let last = peer.mappingLast, now-last >= 0.05-1e-9,
                  let page = try? remoteMappingLabelPage(id,page:index,sequence:frame.sequence),
                  (try? page.encoded()) != nil else { return .close(revokeRemote(id)) }
            peer.labelStarted = true
            peer.mappingLast = now
            peer.labelNext += 1
            peer.labelComplete = peer.labelNext == page.pages
            remotePeers[id] = peer
            return .accepted([])
        case .release:
            let commands = peer.routerSession.map { router.disconnect($0) } ?? []
            peer.routerSession = nil
            peer.lastTouch = nil
            remotePeers[id] = peer
            return .accepted(commands)
        case .touch:
            guard touchSources.contains(peer.source) else { return .close(revokeRemote(id)) }
            if peer.routerSession == nil { peer.routerSession = try? router.connect(peer.source, now: now) }
            guard let session = peer.routerSession, let x = frame.x, let y = frame.y
            else { return .close(revokeRemote(id)) }
            peer.lastTouch = now
            remotePeers[id] = peer
            var commands: [SensorCommand] = []
            for (signal, value): (SensorSignal, Double) in [(.x,x),(.y,y),(.contact,1)] {
                sequence &+= 1
                commands += router.ingest(.init(session: session, signal: signal, value: value,
                                                sequence: sequence, timestamp: now), now: now)
            }
            return .accepted(commands)
        case .orientationArm:
            guard motionSources.contains(peer.source),
                  peer.tilt == nil, let angles = frame.angles,
                  let calibration = RemoteTiltCalibration(neutral: angles),
                  peer.motionFreshness.arm(receipt: now, now: now)
            else { return .close(revokeRemote(id)) }
            peer.tilt = calibration
            peer.lastOrientation = now
            remotePeers[id] = peer
            return .accepted([])
        case .orientation:
            guard let tilt = peer.tilt, let angles = frame.angles,
                  peer.motionFreshness.accept(receipt: now, now: now)
            else { return .close(revokeRemote(id)) }
            if peer.motionSession == nil { peer.motionSession = try? router.connect(peer.source, now: now) }
            guard let session = peer.motionSession else { return .close(revokeRemote(id)) }
            peer.lastOrientation = now
            remotePeers[id] = peer
            let values = tilt.normalize(angles)
            var commands: [SensorCommand] = []
            for (signal, value): (SensorSignal, Double) in [(.tiltYaw, values.yaw), (.tiltPitch, values.pitch), (.tiltRoll, values.roll)] {
                sequence &+= 1
                commands += router.ingest(.init(session: session, signal: signal, value: value,
                                                sequence: sequence, timestamp: now), now: now)
            }
            return .accepted(commands)
        case .motionRelease:
            guard peer.tilt != nil else { return .close(revokeRemote(id)) }
            let commands = peer.motionSession.map { router.disconnect($0) } ?? []
            peer.motionSession = nil
            peer.tilt = nil
            peer.lastOrientation = nil
            peer.motionFreshness.disarm()
            remotePeers[id] = peer
            return .accepted(commands)
        case .pedalboard:
            guard let mask = frame.mask, let levels = frame.levels,
                  let allowed = pedalMasks[peer.source], mask & ~allowed == 0
            else { return .close(revokeRemote(id)) }
            if mask == 0 {
                let commands = peer.pedalSession.map { router.disconnect($0) } ?? []
                peer.pedalSession = nil; peer.pedalMask = 0; peer.lastPedalReceipt = nil
                remotePeers[id] = peer
                return .accepted(commands)
            }
            if peer.pedalSession == nil { peer.pedalSession = try? router.connect(peer.source, now: now) }
            guard let session = peer.pedalSession else { return .close(revokeRemote(id)) }
            var commands: [SensorCommand] = []
            for (index, signal) in RemotePedalboard.signals.enumerated() where mask & (1 << index) != 0 {
                sequence &+= 1
                commands += router.ingest(.init(session: session, signal: signal, value: levels[index],
                                                sequence: sequence, timestamp: now), now: now)
            }
            for (index, signal) in RemotePedalboard.signals.enumerated() where mask & (1 << index) == 0 && peer.pedalMask & (1 << index) != 0 {
                commands += router.releaseSignal(session: session, signal: signal)
            }
            peer.pedalMask = mask; peer.lastPedalReceipt = now
            remotePeers[id] = peer
            return .accepted(commands)
        case .pianoKeys:
            guard let mask = frame.mask, let allowed = pianoMasks[peer.source], mask & ~allowed == 0
            else { return .close(revokeRemote(id)) }
            if mask == 0 {
                let commands = peer.pianoSession.map { router.disconnect($0) } ?? []
                peer.pianoSession = nil; peer.pianoMask = 0; peer.lastPianoReceipt = nil
                remotePeers[id] = peer
                return .accepted(commands)
            }
            if peer.pianoSession == nil { peer.pianoSession = try? router.connect(peer.source, now: now) }
            guard let session = peer.pianoSession else { return .close(revokeRemote(id)) }
            var commands: [SensorCommand] = []
            // Engage sustain before new notes; release it after old notes.
            // Add owners before removing old ones, preserving shared notes.
            let indices = Array(RemotePiano.signals.indices)
            for index in indices.reversed() where mask & (1 << index) != 0 && peer.pianoMask & (1 << index) == 0 {
                sequence &+= 1
                commands += router.ingest(.init(session: session, signal: RemotePiano.signals[index], value: 1,
                                                sequence: sequence, timestamp: now), now: now)
            }
            for index in indices where mask & (1 << index) == 0 && peer.pianoMask & (1 << index) != 0 {
                commands += router.releaseSignal(session: session, signal: RemotePiano.signals[index])
            }
            peer.pianoMask = mask; peer.lastPianoReceipt = now
            remotePeers[id] = peer
            return .accepted(commands)
        case .drumPads:
            guard let mask = frame.mask, let allowed = drumMasks[peer.source], mask & ~allowed == 0
            else { return .close(revokeRemote(id)) }
            if mask == 0 {
                let commands = peer.drumSession.map { router.disconnect($0) } ?? []
                peer.drumSession = nil; peer.drumMask = 0; peer.lastDrumReceipt = nil
                remotePeers[id] = peer
                return .accepted(commands)
            }
            if peer.drumSession == nil { peer.drumSession = try? router.connect(peer.source, now: now) }
            guard let session = peer.drumSession else { return .close(revokeRemote(id)) }
            var commands: [SensorCommand] = []
            // Add new owners before removing old ones. A shared destination
            // stays held when transferred between pads in one snapshot.
            for (index, signal) in RemoteDrumPads.signals.enumerated() where mask & (1 << index) != 0 && peer.drumMask & (1 << index) == 0 {
                sequence &+= 1
                commands += router.ingest(.init(session: session, signal: signal, value: 1,
                                                sequence: sequence, timestamp: now), now: now)
            }
            for (index, signal) in RemoteDrumPads.signals.enumerated() where mask & (1 << index) == 0 && peer.drumMask & (1 << index) != 0 {
                commands += router.releaseSignal(session: session, signal: signal)
            }
            peer.drumMask = mask; peer.lastDrumReceipt = now
            remotePeers[id] = peer
            return .accepted(commands)
        case .accelerationArm, .rotationArm:
            let signal: SensorSignal = frame.kind == .accelerationArm ? .accelerationMagnitude : .rotationMagnitude
            guard inertialSignals[peer.source]?.contains(signal) == true, peer.inertial[signal] == nil
            else { return .close(revokeRemote(id)) }
            var stream = RemoteInertialStream(lastReceipt: now, session: nil)
            if signal == .accelerationMagnitude, let settings = strikeSettings[peer.source] {
                stream.strikeDetector = AirStrikeDetector(settings: settings)
            }
            peer.inertial[signal] = stream
            remotePeers[id] = peer
            return .accepted([])
        case .acceleration, .rotation:
            let signal: SensorSignal = frame.kind == .acceleration ? .accelerationMagnitude : .rotationMagnitude
            guard var stream = peer.inertial[signal], now > stream.lastReceipt, let value = frame.inertialValue
            else { return .close(revokeRemote(id)) }
            if stream.session == nil { stream.session = try? router.connect(peer.source, now: now) }
            guard let session = stream.session else { return .close(revokeRemote(id)) }
            stream.lastReceipt = now
            var commands: [SensorCommand] = []
            if let deadline = stream.strikeReleaseAt, now >= deadline {
                commands += router.releaseSignal(session: session, signal: .airStrike)
                stream.strikeReleaseAt = nil
            }
            sequence &+= 1
            commands += router.ingest(.init(session: session, signal: signal, value: value,
                                            sequence: sequence, timestamp: now), now: now)
            if signal == .accelerationMagnitude, strikeSettings[peer.source] != nil,
               let strength = stream.strikeDetector.ingest(value, now: now),
               stream.strikeReleaseAt == nil {
                sequence &+= 1
                commands += router.ingest(.init(session: session, signal: .airStrike, value: strength,
                                                sequence: sequence, timestamp: now), now: now)
                stream.strikeReleaseAt = now + Self.strikeDuration
            }
            peer.inertial[signal] = stream
            remotePeers[id] = peer
            return .accepted(commands)
        case .accelerationRelease, .rotationRelease:
            let signal: SensorSignal = frame.kind == .accelerationRelease ? .accelerationMagnitude : .rotationMagnitude
            guard let stream = peer.inertial.removeValue(forKey: signal) else { return .close(revokeRemote(id)) }
            let commands = stream.session.map { router.disconnect($0) } ?? []
            remotePeers[id] = peer
            return .accepted(commands)
        }
    }

    public mutating func revokeRemote(_ id: UUID) -> [SensorCommand] {
        router.disconnect(sessions:removeRemoteSessions(id))
    }

    private mutating func removeRemoteSessions(_ id: UUID) -> Set<UUID> {
        guard let peer = remotePeers.removeValue(forKey:id) else { return [] }
        let inertialSessions = [SensorSignal.accelerationMagnitude,.rotationMagnitude].compactMap { peer.inertial[$0]?.session }
        return Set([peer.routerSession,peer.motionSession,peer.drumSession,peer.pianoSession,peer.pedalSession].compactMap { $0 } + inertialSessions)
    }

    public mutating func cancelRemotePairing() { pairing.clear() }

    /// Stop remote admission and release remote owners without disturbing local inputs.
    public mutating func disableRemote() -> [SensorCommand] {
        remoteEnabled = false
        pairing.clear()
        mappingProjections = [:]
        let ids = Array(remotePeers.keys)
        var removed: Set<UUID> = []
        for id in ids { removed.formUnion(removeRemoteSessions(id)) }
        return router.disconnect(sessions:removed)
    }

    public mutating func expire(now: Double) -> [SensorCommand] {
        guard now.isFinite else { return [] }
        let dualExpired = (airDualEnabled || cameraHandsEnabled) && (seen[.camera].map { now - $0 >= 0.25 } ?? false)
        if dualExpired { airDual.reset(); airActiveSlot = nil; airStrum?.reset(); cameraHands.reset() }
        // Remove all expired owners atomically, including camera and remote.
        let stale = sessions.keys.filter {
            ($0 == .camera && dualExpired) || now - (seen[$0] ?? 0) >= Self.timeout
        }.sorted { $0.rawValue < $1.rawValue }
        var removed: Set<UUID> = []
        for source in stale {
            if GamepadFrame.sources.contains(source) {
                gamepadArmed.remove(source); seen.removeValue(forKey:source)
                lastGamepadActive.removeValue(forKey:source)
            }
            if let id = sessions.removeValue(forKey:source) { removed.insert(id) }
        }
        let expiredPeers = remotePeers.filter { $0.value.expired(now:now) }.map(\.key)
        for id in expiredPeers { removed.formUnion(removeRemoteSessions(id)) }
        if let id = hybridSession,let last = hybridReceipt, now < last || now-last >= Self.timeout {
            removed.insert(id); hybridSession = nil; hybridReceipt = nil
        }
        var commands = router.disconnect(sessions:removed)
        if let camera = sessions[.camera], airStrum != nil {
            commands += airStrum!.expire(now:now,session:camera,router:&router)
        }
        for id in remotePeers.keys.sorted(by: { $0.uuidString < $1.uuidString }) {
            guard var peer = remotePeers[id], var stream = peer.inertial[.accelerationMagnitude],
                  let deadline = stream.strikeReleaseAt, now >= deadline, let session = stream.session else { continue }
            commands += router.releaseSignal(session: session, signal: .airStrike)
            stream.strikeReleaseAt = nil
            peer.inertial[.accelerationMagnitude] = stream
            remotePeers[id] = peer
        }
        return commands
    }

    /// Camera failure must not revoke unrelated physical or remote owners.
    public mutating func releaseCamera() -> [SensorCommand] {
        cameraHands.reset()
        airStrum?.reset()
        airDual.reset()
        airActiveSlot = nil
        return disconnect(.camera)
    }

    private mutating func disconnect(_ source: SensorSource) -> [SensorCommand] {
        guard let id = sessions.removeValue(forKey: source) else { return [] }
        return router.disconnect(id)
    }

    public mutating func stop() -> [SensorCommand] {
        cameraHands.reset(); cameraHandsEnabled = false
        airDual = AirDualHandPerformance(); airDualEnabled = false; airHelperEnabled = false; airActiveSlot = nil; airStrum = nil
        sessions = [:]
        hybridSource = nil; hybridInputs = []; hybridSession = nil; hybridReceipt = nil
        seen = [:]
        gamepadArmed = []
        gamepadMappedSignals = [:]
        gamepadSmoothedSources = []
        lastGamepadActive = [:]
        supported = []
        motionSources = []
        touchSources = []
        inertialSignals = [:]
        strikeSettings = [:]
        drumMasks = [:]
        pianoMasks = [:]
        pedalMasks = [:]
        mappingProjections = [:]
        remoteEnabled = false
        pairing.clear()
        remotePeers = [:]
        return router.panic()
    }
}
