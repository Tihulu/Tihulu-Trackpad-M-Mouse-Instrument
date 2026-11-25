/// Bounded display history only. Never queues or changes MIDI delivery.
public enum BuilderCommandMonitor {
    public static let limit = 24

    /// Bounded pending display data. No musical timing or delivery lives here.
    public struct Buffer: Sendable {
        private var pending: [SensorCommand] = []
        public init() {}
        public mutating func append(_ attempted: [SensorCommand]) {
            guard !attempted.isEmpty else { return }
            pending.append(contentsOf:attempted.suffix(BuilderCommandMonitor.limit))
            if pending.count > BuilderCommandMonitor.limit {
                pending.removeFirst(pending.count-BuilderCommandMonitor.limit)
            }
        }
        public mutating func flush(previous: [String]) -> [String]? {
            guard !pending.isEmpty else { return nil }
            let result = BuilderCommandMonitor.updated(previous,attempted:pending)
            pending.removeAll(keepingCapacity:true)
            return result
        }
    }

    public static func updated(_ previous: [String], attempted: [SensorCommand]) -> [String] {
        let recent = attempted.suffix(limit).reversed().map { command in
            let target = command.destination
            return "Ch \(target.channel+1) · \(target.kind.rawValue) \(target.number) → \(command.value)"
        }
        return recent + previous.prefix(max(0,limit-recent.count))
    }
}
