import Foundation

/// Declarative editable instrument, with no executable code or permission data.
public struct InstrumentPatch: Codable, Equatable, Sendable {
    public var name: String
    public var routes: [SensorMapping]
    public var performanceLayout: PerformanceLayout?
    public init(name: String = "Untitled instrument", routes: [SensorMapping] = [],
                performanceLayout: PerformanceLayout? = nil) {
        self.name = name
        self.routes = routes
        self.performanceLayout = performanceLayout
    }

    public static func permits(_ route: SensorMapping) -> Bool {
        guard route.isValid, AirDualHandPerformance.permits(route), AirStrumPerformance.permits(route), AirHandsHelper.permits(route), RemoteDrumPads.permits(route), RemotePiano.permits(route), RemotePedalboard.permits(route) else { return false }
        // Protect channel configuration and bank switching in generic patches.
        return route.destination.kind != .controlChange ||
            ![0,6,32,38,96,97,98,99,100,101].contains(route.destination.number)
    }

    public var isValid: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        name.utf8.count <= 128 &&
        !name.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) } &&
        routes.count <= SensorRouter.maxMappings &&
        Set(routes.map(\.id)).count == routes.count &&
        routes.allSatisfy(Self.permits) && AirDualHandPerformance.permitsCombination(routes) && AirHandsHelper.permitsCombination(routes) && ContinuousResponse.releaseValues(for: routes) != nil &&
        AirDrumSensitivity.settings(for: routes) != nil &&
        (performanceLayout?.isValid ?? true)
    }

    public static var starter: Self {
        .init(name: "Expressive controller", routes: [
            .init(id: "note", source: .trackpad, signal: .contact, destination: .init(.note, number: 60)),
            .init(id: "bend", source: .trackpad, signal: .x, destination: .init(.pitchBend)),
            .init(id: "filter", source: .magicMouse, signal: .y, destination: .init(.controlChange, number: 74))
        ])
    }

    public func archive() throws -> Data {
        guard isValid else { throw WorkspaceArchiveError.invalidPayload }
        return try WorkspaceArchive.encode(name: name, payload: self)
    }

    public static func read(_ data: Data) throws -> Self {
        let patch = try WorkspaceArchive.decode(Self.self, from: data).payload
        guard patch.isValid else { throw WorkspaceArchiveError.invalidPayload }
        return patch
    }
}

/// One simulator session per source kind. Distinct signals share the source
/// session; the router's ownership and calibration are the production core.
public struct PatchSimulation: Sendable {
    public struct Input: Hashable, Identifiable, Sendable {
        public let source: SensorSource
        public let signal: SensorSignal
        public var id: String { source.rawValue + ":" + signal.rawValue }
        public init(source: SensorSource, signal: SensorSignal) {
            self.source = source
            self.signal = signal
        }
    }
    private var router = SensorRouter()
    private var sessions: [SensorSource: UUID] = [:]
    private var sequence: UInt64 = 0
    public private(set) var inputs: [Input] = []
    private var airDual = AirDualHandPerformance()
    public private(set) var hasDualCamera = false
    private var airLastFrame: Double?
    private var airHelperEnabled = false
    private var airActiveSlot: Int?
    private var airStrum: AirStrumPerformance?
    private var cameraHands = AirHandsHelper()
    public private(set) var hasHelperHands = false
    public var airSelectedSlot: Int? { airDual.trackingReady ? airDual.selectedSlot : nil }
    public var airSoundingSlot: Int? {
        if let airStrum, !airStrum.hasActivePulses { return nil }
        return airDual.soundingSlot
    }
    public var running: Bool { !sessions.isEmpty || hasDualCamera || hasHelperHands }
    public init() {}

    public mutating func start(_ patch: InstrumentPatch, now: Double) throws {
        guard !running, patch.isValid, !patch.routes.isEmpty else { throw SensorRouterError.invalidMappings }
        var next = SensorRouter()
        try next.configure(patch.routes)
        var ids: [SensorSource: UUID] = [:]
        let sources = Set(patch.routes.map(\.source))
        let dual = AirDualHandPerformance.usesDualCamera(patch.routes)
        let helper = AirHandsHelper.uses(patch.routes)
        for source in SensorSource.allCases where sources.contains(source) && !((dual || helper) && source == .camera) {
            ids[source] = try next.connect(source, now: now)
        }
        router = next
        sessions = ids
        hasDualCamera = dual
        hasHelperHands = helper
        cameraHands.reset()
        airStrum = AirStrumPerformance(routes:patch.routes)
        airHelperEnabled = dual && AirDualHandPerformance.hasHelperRoutes(patch.routes)
        airDual = AirDualHandPerformance()
        airLastFrame = nil
        airActiveSlot = nil
        sequence = 0
        inputs = Array(Set(patch.routes.filter { !((dual || helper) && $0.source == .camera) }.map { Input(source: $0.source, signal: $0.signal) }))
            .sorted { $0.id < $1.id }
    }

    public mutating func send(_ input: Input, value: Double, now: Double) -> [SensorCommand] {
        guard inputs.contains(input), let id = sessions[input.source] else { return [] }
        sequence &+= 1
        return router.ingest(.init(session: id, signal: input.signal, value: value,
                                   sequence: sequence, timestamp: now), now: now)
    }

    public mutating func release(_ input: Input) -> [SensorCommand] {
        guard inputs.contains(input), let id = sessions[input.source] else { return [] }
        return router.releaseSignal(session: id, signal: input.signal)
    }

    public mutating func receiveHelperHands(left:AirHandSample?,right:AirHandSample?,
                                            time:Double,now:Double) -> [SensorCommand] {
        guard hasHelperHands, !hasDualCamera else { return [] }
        guard time.isFinite, now.isFinite, time >= 0, now >= time, now-time < 0.25,
              airLastFrame.map({ time > $0 }) ?? true else { return releaseDualHand() }
        if let last = airLastFrame, time-last >= 0.25 {
            let release = releaseDualHand()
            airLastFrame = time
            return release
        }
        airLastFrame = time
        if left == nil && right == nil { return releaseDualHand() }
        if sessions[.camera] == nil { sessions[.camera] = try? router.connect(.camera,now:time) }
        guard let session = sessions[.camera] else { return releaseDualHand() }
        return cameraHands.receive(left:left,right:right,time:time,now:now,
                                   session:session,router:&router,sequence:&sequence)
    }

    /// Single timestamp and single reserved session for both camera roles.
    public mutating func receiveCombinedHands(count:Int?,confidence:Double,left:AirHandSample?,
                                              right:AirHandSample?,swapRoles:Bool,
                                              time:Double,now:Double) -> [SensorCommand] {
        guard hasDualCamera, hasHelperHands else { return [] }
        guard time.isFinite,now.isFinite,time >= 0,now >= time,now-time < 0.25,
              airLastFrame.map({ time > $0 }) ?? true else { return releaseDualHand() }
        if let last = airLastFrame, time-last >= 0.25 {
            let commands = releaseDualHand()
            airLastFrame = time
            return commands
        }
        airLastFrame = time
        guard left != nil || right != nil else { return releaseDualHand() }
        if sessions[.camera] == nil { sessions[.camera] = try? router.connect(.camera,now:time) }
        guard let session = sessions[.camera] else { return releaseDualHand() }
        let helper = swapRoles ? left : right
        let chord = swapRoles ? right : left
        let slot = airDual.receive(count:chord == nil ? nil : count,confidence:confidence,
                                   helper:helper,time:time,now:now)
        var commands = cameraHands.receive(left:left,right:right,time:time,now:now,
                                           session:session,router:&router,sequence:&sequence)
        guard let helper, slot != nil || (airHelperEnabled && airDual.trackingReady) else {
            commands += AirHandsHelper.releaseInstrument(session:session,router:&router)
            airStrum?.reset()
            airActiveSlot = nil
            return commands
        }
        commands += AirDualHandPerformance.route(slot:airStrum == nil ? slot : nil,
                                                 previous:airStrum == nil ? airActiveSlot : nil,
                                                 helper:helper,session:session,time:time,router:&router,sequence:&sequence)
        if airStrum != nil {
            commands += airStrum!.update(slot:slot,position:helper.x,time:time,now:now,
                                         session:session,router:&router,sequence:&sequence)
        }
        airActiveSlot = slot
        return commands
    }

    public mutating func receiveDualHand(count: Int?, confidence: Double, helper: AirHandSample?,
                                         time: Double, now: Double) -> [SensorCommand] {
        guard hasDualCamera, !hasHelperHands else { return [] }
        guard time.isFinite, now.isFinite, time >= 0, now >= time, now-time < 0.25,
              airLastFrame.map({ time > $0 }) ?? true else { return releaseDualHand() }
        airLastFrame = time
        let slot = airDual.receive(count: count, confidence: confidence, helper: helper, time: time, now: now)
        guard let helper, slot != nil || (airHelperEnabled && airDual.trackingReady) else {
            airActiveSlot = nil
            airStrum?.reset()
            guard let session = sessions.removeValue(forKey: .camera) else { return [] }
            return router.disconnect(session)
        }
        if sessions[.camera] == nil { sessions[.camera] = try? router.connect(.camera, now: time) }
        guard let session = sessions[.camera] else { return releaseDualHand() }
        var commands = AirDualHandPerformance.route(slot: airStrum == nil ? slot : nil, previous: airStrum == nil ? airActiveSlot : nil, helper: helper,
                                                    session: session, time: time, router: &router, sequence: &sequence)
        if airStrum != nil {
            commands += airStrum!.update(slot:slot,position:helper.x,time:time,now:now,session:session,router:&router,sequence:&sequence)
        }
        airActiveSlot = slot
        return commands
    }

    public mutating func releaseDualHand() -> [SensorCommand] {
        cameraHands.reset()
        airStrum?.reset()
        airDual.reset()
        airActiveSlot = nil
        guard let session = sessions.removeValue(forKey: .camera) else { return [] }
        return router.disconnect(session)
    }

    public mutating func expireDualHand(now: Double) -> [SensorCommand] {
        guard (hasDualCamera || hasHelperHands), let last = airLastFrame else { return [] }
        guard now.isFinite, now >= last, now - last < 0.25 else { return releaseDualHand() }
        if let camera = sessions[.camera], airStrum != nil {
            return airStrum!.expire(now:now,session:camera,router:&router)
        }
        return []
    }

    public mutating func disconnect(_ source: SensorSource) -> [SensorCommand] {
        if source == .camera && (hasDualCamera || hasHelperHands) {
            hasDualCamera = false
            hasHelperHands = false
            return releaseDualHand()
        }
        guard let id = sessions.removeValue(forKey: source) else { return [] }
        inputs.removeAll { $0.source == source }
        return router.disconnect(id)
    }

    public mutating func stop() -> [SensorCommand] {
        hasHelperHands = false
        cameraHands.reset()
        hasDualCamera = false
        airStrum = nil
        airHelperEnabled = false
        airDual = AirDualHandPerformance()
        airLastFrame = nil
        airActiveSlot = nil
        inputs = []
        sessions = [:]
        return router.panic()
    }
}

/// Delivery ledger includes continuous controls and sustain as well as notes.
/// Retain attempted state until the receiver accepts its neutral command.
public struct PatchOutputLedger: Sendable {
    public private(set) var outstanding: Set<SensorDestination> = []
    private var releases: [SensorDestination:Int] = [:]
    public init() {}
    public static func neutral(_ target: SensorDestination) -> Int {
        ContinuousResponse.defaultRelease(target)
    }
    /// A running or failed-release ledger must never change its reset policy.
    public mutating func configure(_ patch: InstrumentPatch) throws {
        guard outstanding.isEmpty, patch.isValid,
              let values = ContinuousResponse.releaseValues(for: patch.routes)
        else { throw WorkspaceArchiveError.invalidPayload }
        releases = values
    }
    private func releaseValue(_ target: SensorDestination) -> Int {
        releases[target] ?? Self.neutral(target)
    }
    public mutating func deliver(_ command: SensorCommand, send: (SensorCommand) -> Bool) -> Bool {
        let target = command.destination
        guard target.isValid else { return false }
        let neutral = releaseValue(target)
        // Even a failed neutral command remains eligible for retry.
        outstanding.insert(target)
        guard send(command) else { return false }
        if command.value == neutral { outstanding.remove(target) }
        return true
    }

    public mutating func releaseAll(send: (SensorCommand) -> Bool) -> Bool {
        let targets = outstanding.sorted {
            let a = $0.kind == .note ? 0 : ($0.kind == .sustain ? 1 : 2)
            let b = $1.kind == .note ? 0 : ($1.kind == .sustain ? 1 : 2)
            if a != b { return a < b }
            if $0.channel != $1.channel { return $0.channel < $1.channel }
            if $0.kind.rawValue != $1.kind.rawValue { return $0.kind.rawValue < $1.kind.rawValue }
            return $0.number < $1.number
        }
        for target in targets {
            if send(.init(target, value: releaseValue(target))) { outstanding.remove(target) }
        }
        return outstanding.isEmpty
    }
}
