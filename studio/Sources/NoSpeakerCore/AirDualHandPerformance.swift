import Foundation

/// Shared physical and replay input. Native adapter resolves chirality before
/// calling this engine; ambiguous or missing hands are represented by nil.
public struct AirDualHandPerformance: Sendable {
    public static let signals: [SensorSignal] = [.airChord1, .airChord2, .airChord3, .airChord4, .airChord5]
    public static let defaultBank = [[60,64,67],[62,65,69],[64,67,71],[65,69,72],[67,71,74]]
    private var selection = AirChordSelection(slots: defaultBank)!
    private var pinch = AirPinchGate()
    public private(set) var soundingSlot: Int?
    public private(set) var trackingReady = false
    public var selectedSlot: Int? { selection.selectedSlot }
    public init() {}

    public mutating func reset() {
        _ = selection.invalidate()
        pinch.reset()
        soundingSlot = nil
        trackingReady = false
    }

    public mutating func receive(count: Int?, confidence: Double, helper: AirHandSample?,
                                 time: Double, now: Double) -> Int? {
        guard time.isFinite, now.isFinite, time >= 0, now >= time,
              now - time < 0.25, let helper, let count, (0...5).contains(count),
              confidence.isFinite, (0.75...1).contains(confidence) else { reset(); return nil }
        let change = selection.observe(count: count, confidence: confidence, time: time)
        if change == .releaseOwned {
            pinch.reset()
            soundingSlot = nil
            trackingReady = false
            return nil
        }
        // A pending chord must not trigger the previous selection.
        trackingReady = selection.selectedSlot == count && count > 0
        soundingSlot = pinch.update(aperture: helper.aperture, selectedSlot: trackingReady ? selection.selectedSlot : nil)
        return soundingSlot
    }

    /// Shared routing for live camera and synthetic frame debugging.
    static func route(slot: Int?, previous: Int?, helper: AirHandSample,
                      session: UUID, time: Double, router: inout SensorRouter,
                      sequence: inout UInt64) -> [SensorCommand] {
        guard slot.map({ (1...5).contains($0) }) ?? true else { return [] }
        var commands: [SensorCommand] = []
        if let previous, previous != slot, (1...5).contains(previous) {
            commands += router.releaseSignal(session: session, signal: signals[previous - 1])
        }
        if slot == nil && previous != nil {
            commands += router.releaseSignal(session: session, signal: .contact)
        }
        var values: [(SensorSignal,Double)] = [(.x,helper.x),(.y,helper.y),(.gesture,helper.aperture)]
        if slot != nil { values.append((.contact,1)) }
        for (signal,value) in values {
            sequence &+= 1
            commands += router.ingest(.init(session: session, signal: signal, value: value,
                                             sequence: sequence, timestamp: time), now: time)
        }
        if let slot, previous != slot {
            sequence &+= 1
            commands += router.ingest(.init(session: session, signal: signals[slot - 1], value: 1,
                                             sequence: sequence, timestamp: time), now: time)
        }
        return commands
    }

    public static func permits(_ route: SensorMapping) -> Bool {
        guard signals.contains(route.signal) else { return true }
        return route.source == .camera && route.destination.kind == .note &&
            (route.calibration.apply(1) ?? -1) >= route.threshold
    }

    public static func usesDualCamera(_ routes: [SensorMapping]) -> Bool {
        routes.contains { $0.source == .camera && signals.contains($0.signal) } || AirStrumPerformance.usesStrum(routes)
    }

    public static let helperSignals: Set<SensorSignal> = [.x,.y,.gesture]

    public static func hasHelperRoutes(_ routes: [SensorMapping]) -> Bool {
        routes.contains { $0.source == .camera && helperSignals.contains($0.signal) &&
            ContinuousResponse.isContinuous($0.destination) }
    }

    /// In dual-hand mode the free helper axes must never trigger a note.
    public static func permitsCombination(_ routes: [SensorMapping]) -> Bool {
        guard usesDualCamera(routes) else { return true }
        if AirStrumPerformance.usesStrum(routes) {
            guard !routes.contains(where: { $0.source == .camera && (signals.contains($0.signal) || $0.signal == .contact) }),
                  AirStrumPerformance(routes:routes) != nil else { return false }
        }
        return routes.allSatisfy { route in
            guard route.source == .camera && helperSignals.contains(route.signal) else { return true }
            return ContinuousResponse.isContinuous(route.destination)
        }
    }

    public static func helperRoutes(channel: Int = 0) -> [SensorMapping] {
        guard (0...15).contains(channel) else { return [] }
        return [
            .init(id: "air-helper-bend-\(channel)", source: .camera, signal: .x,
                  destination: .init(.pitchBend, channel: channel),
                  response: .init(smoothingMS: 25)),
            .init(id: "air-helper-expression-\(channel)", source: .camera, signal: .y,
                  destination: .init(.controlChange, channel: channel, number: 11),
                  response: .init(smoothingMS: 35)),
            .init(id: "air-helper-wah-\(channel)", source: .camera, signal: .gesture,
                  destination: .init(.controlChange, channel: channel, number: 74),
                  response: .init(smoothingMS: 30))
        ]
    }

    public static func routes(channel: Int = 0) -> [SensorMapping] {
        guard (0...15).contains(channel) else { return [] }
        return zip(signals, defaultBank).enumerated().flatMap { index, pair in
            pair.1.map { note in
                SensorMapping(id: "air-chord-\(index)-\(note)", source: .camera,
                              signal: pair.0, destination: .init(.note, channel: channel, number: note))
            }
        }
    }
}
