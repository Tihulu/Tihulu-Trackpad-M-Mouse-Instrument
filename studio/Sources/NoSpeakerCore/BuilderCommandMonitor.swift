/// Bounded display history only. Never queues or changes MIDI delivery.
public enum BuilderCommandMonitor {
    public static let limit = 24

    public static func updated(_ previous: [String], attempted: [SensorCommand]) -> [String] {
        let recent = attempted.suffix(limit).reversed().map { command in
            let target = command.destination
            return "Ch \(target.channel+1) · \(target.kind.rawValue) \(target.number) → \(command.value)"
        }
        return recent + previous.prefix(max(0,limit-recent.count))
    }
}
