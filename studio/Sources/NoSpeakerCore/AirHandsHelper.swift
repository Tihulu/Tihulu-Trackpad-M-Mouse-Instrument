import Foundation

/// Two independently acquired physical hands, sharing one camera session.
/// No chord selection or note generation is needed. No inferred pressure.
public struct AirHandsHelper: Sendable {
    public enum Hand: String, CaseIterable, Identifiable, Sendable {
        case left, right
        public var id: String { rawValue }
        public var signals: [SensorSignal] {
            switch self {
            case .left: [.airLeftX,.airLeftY,.airLeftAperture,.airLeftPinch,.airLeftSpeed,.airLeftToggle]
            case .right: [.airRightX,.airRightY,.airRightAperture,.airRightPinch,.airRightSpeed,.airRightToggle]
            }
        }
    }
    public enum Effect: String, CaseIterable, Identifiable, Sendable {
        case pitchBend, expression, volume, wah, vibrato, vibratoRate, modulation, breath, sustain, sostenuto, softPedal, pan, portamento, resonance, customCC
        public var id: String { rawValue }
        public var title: String {
            switch self {
            case .pitchBend: "Pitch bend"
            case .wah: "Wah / filter"
            case .customCC: "Custom CC"
            case .vibrato: "Vibrato depth"
            case .vibratoRate: "Vibrato rate"
            default: rawValue.capitalized
            }
        }
        public var destination: SensorDestination {
            switch self {
            case .pitchBend: .init(.pitchBend)
            case .sustain: .init(.sustain)
            case .expression: .init(.controlChange,number:11)
            case .volume: .init(.controlChange,number:7)
            case .wah: .init(.controlChange,number:74)
            case .vibrato: .init(.controlChange,number:77)
            case .vibratoRate: .init(.controlChange,number:76)
            case .modulation: .init(.controlChange,number:1)
            case .breath: .init(.controlChange,number:2)
            case .sostenuto: .init(.controlChange,number:66)
            case .softPedal: .init(.controlChange,number:67)
            case .pan: .init(.controlChange,number:10)
            case .portamento: .init(.controlChange,number:65)
            case .resonance: .init(.controlChange,number:71)
            case .customCC: .init(.controlChange,number:12)
            }
        }
        public var isSwitch: Bool { [.sustain,.sostenuto,.softPedal,.portamento].contains(self) }
    }
    public enum Axis: String, CaseIterable, Identifiable, Sendable {
        case x,y,aperture,pinch,speed,toggle
        public var id: String { rawValue }
        public var index: Int {
            switch self { case .x:0; case .y:1; case .aperture:2; case .pinch:3; case .speed:4; case .toggle:5 }
        }
    }
    public static let pedalSignals: Set<SensorSignal> = [.airLeftPinch,.airRightPinch,.airLeftToggle,.airRightToggle]
    static func isSwitchTarget(_ target:SensorDestination) -> Bool {
        target.kind == .sustain || (target.kind == .controlChange && [65,66,67,69].contains(target.number))
    }
    /// Opt into OR ownership only when a camera pedal is configured. Legacy
    /// continuous CC mappings are not silently converted into switches.
    static func sharedSwitchTargets(_ routes:[SensorMapping]) -> Set<SensorDestination>? {
        let targets = Set(routes.filter { $0.source == .camera && pedalSignals.contains($0.signal) &&
            $0.destination.kind == .controlChange && isSwitchTarget($0.destination) }.map(\.destination))
        let binary: Set<SensorSignal> = pedalSignals.union([.contact,.pedalSwitch1,.pedalSwitch2,.pianoSustain,.pedalSustain])
        guard routes.allSatisfy({ route in
            !targets.contains(route.destination) || (binary.contains(route.signal) &&
                route.calibration == SensorCalibration() &&
                (route.response == nil || route.response == ContinuousResponse()))
        }) else { return nil }
        return targets
    }
    public static let allSignals = Set(Hand.allCases.flatMap(\.signals))
    public static func uses(_ routes:[SensorMapping]) -> Bool {
        routes.contains { $0.source == .camera && allSignals.contains($0.signal) }
    }
    public static func permits(_ route:SensorMapping) -> Bool {
        guard allSignals.contains(route.signal) else { return true }
        guard route.source == .camera, route.destination.kind != .note else { return false }
        let isPinch = pedalSignals.contains(route.signal)
        let isSwitch = isSwitchTarget(route.destination)
        if isSwitch {
            return isPinch && route.response == nil && route.calibration.apply(1) == 1 && route.calibration.apply(0) == 0
        }
        return ![SensorSignal.airLeftToggle,.airRightToggle].contains(route.signal) && ContinuousResponse.isContinuous(route.destination)
    }
    public static func permitsCombination(_ routes:[SensorMapping]) -> Bool {
        guard uses(routes) else { return true }
        let instrument = AirDualHandPerformance.usesDualCamera(routes)
        let camera = routes.filter { $0.source == .camera }
        let named = camera.filter { allSignals.contains($0.signal) }
        let other = camera.filter { !allSignals.contains($0.signal) }
        // Separate instrument and helper domains must not compete for the
        // same target within a camera frame. Other devices keep shared ownership.
        guard instrument || other.isEmpty else { return false }
        guard Set(named.map(\.destination)).isDisjoint(with:Set(other.map(\.destination))) else { return false }
        return sharedSwitchTargets(routes) != nil
    }

    public static func canAdd(to routes:[SensorMapping]) -> Bool {
        AirDualHandPerformance.usesDualCamera(routes) ||
            !routes.contains { $0.source == .camera && !allSignals.contains($0.signal) }
    }

    static let instrumentSignals = Set(AirDualHandPerformance.signals +
        AirStrumPerformance.strings.flatMap { $0 } + [.x,.y,.gesture,.contact])
    static func releaseInstrument(session:UUID,router:inout SensorRouter) -> [SensorCommand] {
        router.releaseSignals(session:session,signals:instrumentSignals)
    }
    public static func route(hand:Hand,axis:Axis,effect:Effect,channel:Int = 0) -> SensorMapping? {
        guard (0...15).contains(channel), !effect.isSwitch || axis == .pinch || axis == .toggle,
              axis != .toggle || effect.isSwitch else { return nil }
        var destination = effect.destination
        destination.channel = channel
        let response: ContinuousResponse? = effect.isSwitch ? nil :
            .init(smoothingMS:25,release:effect == .pan ? 0.5 : nil)
        return .init(id:UUID().uuidString,source:.camera,signal:hand.signals[axis.index],
                     destination:destination,response:response)
    }
    /// UI-friendly output excursion, separate from the receiving synth's
    /// semitone bend range. No RPN or channel configuration messages.
    public static func configuredRoute(hand:Hand,axis:Axis,effect:Effect,channel:Int,
                                       excursion:Double,smoothingMS:Int,customCC:Int = 12) -> SensorMapping? {
        guard excursion.isFinite,(0.05...1).contains(excursion),(0...250).contains(smoothingMS),
              var route = route(hand:hand,axis:axis,effect:effect,channel:channel) else { return nil }
        if effect == .customCC { route.destination.number = customCC }
        if !effect.isSwitch {
            let centered = effect == .pitchBend || effect == .pan
            route.response = .init(minimum:centered ? (1-excursion)/2 : 0,
                                   maximum:centered ? (1+excursion)/2 : excursion,
                                   smoothingMS:smoothingMS,release:effect == .pan ? 0.5 : nil)
        }
        return InstrumentPatch.permits(route) ? route : nil
    }

    public enum Preset: String, CaseIterable, Identifiable, Sendable {
        case expressive, guitarEffects, pedalPair
        public var id: String { rawValue }
        public var title: String {
            switch self {
            case .expressive: "Expression + modulation"
            case .guitarEffects: "Guitar bend + wah"
            case .pedalPair: "Sustain + sostenuto"
            }
        }
        public func routes(channel:Int) -> [SensorMapping] {
            let assignments: [(Hand,Axis,Effect)]
            switch self {
            case .expressive: assignments = [(.left,.y,.expression),(.right,.y,.modulation)]
            case .guitarEffects: assignments = [(.left,.x,.pitchBend),(.right,.aperture,.wah)]
            case .pedalPair: assignments = [(.left,.pinch,.sustain),(.right,.toggle,.sostenuto)]
            }
            return assignments.compactMap { AirHandsHelper.route(hand:$0.0,axis:$0.1,effect:$0.2,channel:channel) }
        }
    }

    private struct State: Sendable {
        var gate = AirTrackingGate()
        var prior: AirHandSample?
        var time: Double?
        var armed = false
        var pinched = false
        var latched = false
        mutating func values(_ sample:AirHandSample?,time:Double,now:Double) -> [Double]? {
            guard let hand = gate.accept(sample,at:time,now:now) else {
                prior = nil; self.time = nil; armed = false; pinched = false; latched = false
                return nil
            }
            var speed = 0.0
            if let prior, let old = self.time, time > old {
                speed = min(1,hypot(hand.x-prior.x,hand.y-prior.y)/max(0.001,time-old)/5)
            }
            prior = hand; self.time = time
            if hand.aperture >= 0.35 { armed = true; pinched = false }
            if armed && !pinched && hand.aperture <= 0.18 { pinched = true; latched.toggle() }
            return [hand.x,hand.y,hand.aperture,pinched ? 1 : 0,speed,latched ? 1 : 0]
        }
    }
    private var left = State()
    private var right = State()
    public init() {}
    public mutating func reset() { left = State(); right = State() }

    mutating func receive(left l:AirHandSample?,right r:AirHandSample?,time:Double,now:Double,
                          session:UUID,router:inout SensorRouter,sequence:inout UInt64) -> [SensorCommand] {
        let lv = left.values(l,time:time,now:now)
        let rv = right.values(r,time:time,now:now)
        var lost = Set<SensorSignal>()
        if lv == nil { lost.formUnion(Hand.left.signals) }
        if rv == nil { lost.formUnion(Hand.right.signals) }
        var events: [SensorEvent] = []
        for (hand,values) in [(Hand.left,lv),(Hand.right,rv)] {
            guard let values else { continue }
            for (signal,value) in zip(hand.signals,values) {
                sequence &+= 1
                events.append(.init(session:session,signal:signal,value:value,sequence:sequence,timestamp:time))
            }
        }
        return router.ingestFrame(session:session,releasing:lost,events:events,now:time)
    }
}
