import Foundation

/// Explicit host slot, not a model name or mutable OS player index.
public struct GamepadFrame: Sendable {
    public static let orderedSources: [SensorSource] = [.gamepad1,.gamepad2,.gamepad3,.gamepad4]
    public static let sources = Set(orderedSources)
    public static func slotLabel(_ source:SensorSource) -> String {
        orderedSources.firstIndex(of:source).map { "Controller "+String($0+1) } ?? source.rawValue
    }
    public static let buttons:[SensorSignal] = [.padA,.padB,.padX,.padY,.padLB,.padRB,.padUp,.padDown,.padLeft,.padRight,.padLClick,.padRClick]
    public static let triggers:[SensorSignal] = [.padLT,.padRT]
    public static let sticks:[SensorSignal] = [.padLSX,.padLSY,.padRSX,.padRSY]
    public static let signals = buttons+triggers+sticks
    /// Full snapshot: buttons and triggers [0,1], sticks [-1,1].
    public let active:[SensorSignal:Double]
    public init?(buttons:[Double],triggers:[Double],sticks:[Double]) {
        guard buttons.count == Self.buttons.count,triggers.count == Self.triggers.count,sticks.count == Self.sticks.count,
              buttons.allSatisfy({ $0 == 0 || $0 == 1 }),
              triggers.allSatisfy({ $0.isFinite && (0...1).contains($0) }),
              sticks.allSatisfy({ $0.isFinite && (-1...1).contains($0) }) else { return nil }
        var values:[SensorSignal:Double] = [:]
        for (s,v) in zip(Self.buttons,buttons) where v > 0 { values[s] = v }
        for (s,v) in zip(Self.triggers,triggers) where v > 0.05 { values[s] = v }
        for (s,v) in zip(Self.sticks,sticks) where abs(v) > 0.10 {
            values[s] = (v+1)/2
        }
        active = values
    }
    public static func permits(_ route:SensorMapping) -> Bool {
        let source = sources.contains(route.source), signal = signals.contains(route.signal)
        guard source || signal else { return true }
        guard source && signal else { return false }
        if sticks.contains(route.signal) { return ContinuousResponse.isContinuous(route.destination) }
        return true
    }
    public enum Role:String,CaseIterable,Identifiable,Sendable {
        case drums, lead, helper
        public var id:String { rawValue }
        public func routes(source:SensorSource,channel:Int) -> [SensorMapping] {
            guard GamepadFrame.sources.contains(source),(0...15).contains(channel) else { return [] }
            func route(_ signal:SensorSignal,_ kind:SensorDestinationKind,_ number:Int = 0) -> SensorMapping {
                .init(id:source.rawValue+"-"+signal.rawValue,source:source,signal:signal,
                      destination:.init(kind,channel:channel,number:number))
            }
            switch self {
            case .drums: return zip([SensorSignal.padA,.padB,.padX,.padY,.padLB,.padRB,.padUp,.padDown],[36,38,42,46,39,47,49,51]).map { route($0.0,.note,$0.1) }
            case .lead: return zip([SensorSignal.padA,.padB,.padX,.padY],[60,62,64,67]).map { route($0.0,.note,$0.1) } +
                [route(.padLSX,.pitchBend),route(.padRSY,.controlChange,74),route(.padRT,.sustain)]
            case .helper: return [route(.padRT,.sustain),route(.padLT,.controlChange,74),route(.padLSX,.pitchBend),route(.padRSY,.controlChange,1)]
            }
        }
    }
}
