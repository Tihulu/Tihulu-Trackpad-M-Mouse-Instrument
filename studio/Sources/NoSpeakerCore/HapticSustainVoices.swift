/// Local motor voice budget, not a MIDI note limit. Keep at most six
/// retained contacts and always prefer live input to released sustain voices.
public struct HapticSustainVoices<Value: Sendable>: Sendable {
    public static var capacity: Int { 6 }
    private var retained: [(id: String, value: Value)] = []
    public init() {}
    public var count: Int { retained.count }

    public mutating func remember(id: String, value: Value) {
        if let index = retained.firstIndex(where: { $0.id == id }) {
            retained[index].value = value
            return
        }
        if retained.count == Self.capacity { retained.removeFirst() }
        retained.append((id,value))
    }

    public mutating func removeAll() { retained.removeAll(keepingCapacity:true) }

    /// A new pedal admission cannot inherit voices from a previous
    /// performance, disabled motor output or retired output session.
    public static func permitsSustain(requested:Bool,active:Bool,localSound:Bool,
                                      hasValidMapping:Bool,outputHealthy:Bool) -> Bool {
        requested && active && localSound && hasValidMapping && outputHealthy
    }

    /// Input order is normalized for deterministic live selection. Retained
    /// voices fill remaining slots newest-first; duplicate IDs never sound twice.
    public func sounding(live: [(id: String, value: Value)], includeSustained: Bool,
                         transient:[(id:String,value:Value)] = [],
                         permits: (Value) -> Bool = { _ in true }) -> [Value] {
        var result: [Value] = []
        var seen: Set<String> = []
        for entry in live.sorted(by:{ $0.id < $1.id }) {
            guard permits(entry.value),seen.insert(entry.id).inserted else { continue }
            result.append(entry.value)
            if result.count == Self.capacity { return result }
        }
        if includeSustained {
            for entry in retained.reversed() {
                guard permits(entry.value),seen.insert(entry.id).inserted else { continue }
                result.append(entry.value)
                if result.count == Self.capacity { return result }
            }
        }
        // Released sub-tick attacks may fill spare capacity but must not
        // displace a currently sounding finger or sustained voice.
        for entry in transient {
            guard permits(entry.value),seen.insert(entry.id).inserted else { continue }
            result.append(entry.value)
            if result.count == Self.capacity { break }
        }
        return result
    }
}
