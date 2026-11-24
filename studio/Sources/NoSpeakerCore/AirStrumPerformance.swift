import Foundation

/// A single camera session owns all string pulses and helper axes.
/// No extra local/remote router reservation is required.
public struct AirStrumPerformance: Sendable {
    public static let strings: [[SensorSignal]] = [
        [.airString1_1, .airString1_2, .airString1_3, .airString1_4, .airString1_5, .airString1_6, .airString1_7, .airString1_8],
        [.airString2_1, .airString2_2, .airString2_3, .airString2_4, .airString2_5, .airString2_6, .airString2_7, .airString2_8],
        [.airString3_1, .airString3_2, .airString3_3, .airString3_4, .airString3_5, .airString3_6, .airString3_7, .airString3_8],
        [.airString4_1, .airString4_2, .airString4_3, .airString4_4, .airString4_5, .airString4_6, .airString4_7, .airString4_8],
        [.airString5_1, .airString5_2, .airString5_3, .airString5_4, .airString5_5, .airString5_6, .airString5_7, .airString5_8]
    ]
    public static let pulseDuration = 0.12
    private var detector: AirStringCrossing
    private var selected: Int?
    private var deadlines: [SensorSignal:Double] = [:]
    private let mappedSignals: Set<SensorSignal>
    public var hasActivePulses: Bool { !deadlines.isEmpty }

    public init?(routes: [SensorMapping]) {
        let used = Set(routes.filter { $0.source == .camera }.map(\.signal))
        let count = Self.strings.flatMap { row in row.enumerated().compactMap { used.contains($0.element) ? $0.offset + 1 : nil } }.max() ?? 0
        guard count >= 3, let detector = AirStringCrossing(stringCount: count) else { return nil }
        self.detector = detector
        mappedSignals = used
    }

    public static func isStringSignal(_ signal: SensorSignal) -> Bool {
        strings.contains { $0.contains(signal) }
    }

    public static func usesStrum(_ routes: [SensorMapping]) -> Bool {
        routes.contains { $0.source == .camera && isStringSignal($0.signal) }
    }

    public static func permits(_ route: SensorMapping) -> Bool {
        guard isStringSignal(route.signal) else { return true }
        return route.source == .camera && route.destination.kind == .note &&
            (route.calibration.apply(1) ?? -1) >= route.threshold
    }

    public static func routes(bank: [[Int]], channel: Int = 0) -> [SensorMapping] {
        guard bank.count == 5, let count = bank.first?.count, (3...8).contains(count),
              (0...15).contains(channel),
              bank.allSatisfy({ $0.count == count && $0.allSatisfy { (0...127).contains($0) } }) else { return [] }
        return bank.enumerated().flatMap { slot, notes in
            notes.enumerated().map { string, note in
                .init(id: "air-string-\(slot)-\(string)", source: .camera,
                      signal: strings[slot][string], destination: .init(.note,channel:channel,number:note),velocity:127)
            }
        }
    }

    public static let guitarBank = [[48,55,60,64,67,72],[50,57,62,65,69,74],[52,59,64,67,71,76],
                                    [53,60,65,69,72,77],[55,62,67,71,74,79]]
    // Equal-tempered experimental voicings, not an authentic makam tuning.
    public static let threeCourseBank = [[48,55,60],[50,57,62],[52,59,64],[53,60,65],[55,62,67]]

    public mutating func reset() { detector.reset(); selected = nil; deadlines = [:] }

    mutating func expire(now: Double, session: UUID, router: inout SensorRouter) -> [SensorCommand] {
        let due = deadlines.filter { !now.isFinite || now >= $0.value }.keys.sorted { $0.rawValue < $1.rawValue }
        var commands: [SensorCommand] = []
        for signal in due {
            deadlines.removeValue(forKey: signal)
            commands += router.releaseSignal(session: session,signal:signal)
        }
        return commands
    }

    mutating func update(slot: Int?, position: Double, time: Double, now: Double,
                         session: UUID, router: inout SensorRouter, sequence: inout UInt64) -> [SensorCommand] {
        var commands = expire(now:now,session:session,router:&router)
        guard let slot, (1...5).contains(slot), time.isFinite, now.isFinite,
              time >= 0, now >= time, now-time < 0.10 else {
            commands += expire(now:.infinity,session:session,router:&router)
            reset()
            return commands
        }
        if selected != slot {
            commands += expire(now:.infinity,session:session,router:&router)
            detector.reset()
            selected = slot
        }
        for hit in detector.observe(position:position,time:time) {
            let signal = Self.strings[slot-1][hit.string]
            guard mappedSignals.contains(signal) else { continue }
            if deadlines.removeValue(forKey:signal) != nil {
                commands += router.releaseSignal(session:session,signal:signal)
            }
            sequence &+= 1
            commands += router.ingest(.init(session:session,signal:signal,value:Double(hit.velocity)/127,
                                             sequence:sequence,timestamp:time),now:time)
            deadlines[signal] = time + Self.pulseDuration
        }
        return commands
    }
}
