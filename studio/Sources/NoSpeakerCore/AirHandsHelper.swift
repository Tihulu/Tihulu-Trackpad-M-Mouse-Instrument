import Foundation

/// Two independently acquired physical hands, sharing one camera session.
/// No chord selection or note generation is needed. No inferred pressure.
public struct AirHandsHelper: Sendable {
    public enum Hand: String, CaseIterable, Identifiable, Sendable {
        case left, right
        public var id: String { rawValue }
        public var signals: [SensorSignal] {
            switch self {
            case .left: [.airLeftX,.airLeftY,.airLeftAperture,.airLeftPinch,.airLeftSpeed]
            case .right: [.airRightX,.airRightY,.airRightAperture,.airRightPinch,.airRightSpeed]
            }
        }
    }
    public enum Effect: String, CaseIterable, Identifiable, Sendable {
        case pitchBend, expression, volume, wah, vibrato, modulation, breath, sustain, sostenuto, softPedal, pan, portamento, resonance, customCC
        public var id: String { rawValue }
        public var title: String {
            switch self {
            case .pitchBend: "Pitch bend"
            case .wah: "Wah / filter"
            case .customCC: "Custom CC"
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
            case .vibrato: .init(.controlChange,number:76)
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
        case x,y,aperture,pinch,speed
        public var id: String { rawValue }
        public var index: Int {
            switch self { case .x:0; case .y:1; case .aperture:2; case .pinch:3; case .speed:4 }
        }
    }
    public static let allSignals = Set(Hand.allCases.flatMap(\.signals))
    public static func uses(_ routes:[SensorMapping]) -> Bool {
        routes.contains { $0.source == .camera && allSignals.contains($0.signal) }
    }
    public static func permits(_ route:SensorMapping) -> Bool {
        guard allSignals.contains(route.signal) else { return true }
        guard route.source == .camera, route.destination.kind != .note else { return false }
        let isPinch = [SensorSignal.airLeftPinch,.airRightPinch].contains(route.signal)
        let isSwitch = route.destination.kind == .sustain ||
            (route.destination.kind == .controlChange && [65,66,67,69].contains(route.destination.number))
        if isSwitch {
            return isPinch && route.calibration.apply(1) == 1 && route.calibration.apply(0) == 0
        }
        return ContinuousResponse.isContinuous(route.destination)
    }
    public static func permitsCombination(_ routes:[SensorMapping]) -> Bool {
        guard uses(routes) else { return true }
        return routes.allSatisfy { $0.source != .camera || allSignals.contains($0.signal) }
    }
    public static func route(hand:Hand,axis:Axis,effect:Effect,channel:Int = 0) -> SensorMapping? {
        guard (0...15).contains(channel), !effect.isSwitch || axis == .pinch else { return nil }
        var destination = effect.destination
        destination.channel = channel
        let response: ContinuousResponse? = effect.isSwitch ? nil :
            .init(smoothingMS:25,release:effect == .pan ? 0.5 : nil)
        return .init(id:UUID().uuidString,source:.camera,signal:hand.signals[axis.index],
                     destination:destination,response:response)
    }
    private struct State: Sendable {
        var gate = AirTrackingGate()
        var prior: AirHandSample?
        var time: Double?
        var armed = false
        var pinched = false
        mutating func values(_ sample:AirHandSample?,time:Double,now:Double) -> [Double]? {
            guard let hand = gate.accept(sample,at:time,now:now) else {
                prior = nil; self.time = nil; armed = false; pinched = false
                return nil
            }
            var speed = 0.0
            if let prior, let old = self.time, time > old {
                speed = min(1,hypot(hand.x-prior.x,hand.y-prior.y)/max(0.001,time-old)/5)
            }
            prior = hand; self.time = time
            if hand.aperture >= 0.35 { armed = true; pinched = false }
            if armed && hand.aperture <= 0.18 { pinched = true }
            return [hand.x,hand.y,hand.aperture,pinched ? 1 : 0,speed]
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
        var commands = router.releaseSignals(session:session,signals:lost)
        for (hand,values) in [(Hand.left,lv),(Hand.right,rv)] {
            guard let values else { continue }
            for (signal,value) in zip(hand.signals,values) {
                sequence &+= 1
                commands += router.ingest(.init(session:session,signal:signal,value:value,
                                                sequence:sequence,timestamp:time),now:time)
            }
        }
        return commands
    }
}
