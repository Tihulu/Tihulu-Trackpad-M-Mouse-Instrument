/// Incoming MIDI note gates for the haptic bridge and its activity monitor.
public struct LegacyIncomingNotes: Sendable {
    public struct Key: Hashable, Sendable {
        public let channel: Int
        public let note: Int
        public init(channel: Int, note: Int) { self.channel = channel; self.note = note }
    }
    public struct State: Equatable, Sendable {
        public var velocity: Int
        public var keyDownCount: Int
    }
    public private(set) var notes: [Key:State] = [:]
    public private(set) var sustained: Set<Int> = []
    public init() {}
    public mutating func noteOn(channel: Int, note: Int, velocity: Int) -> [SensorCommand] {
        guard (0...15).contains(channel), (0...127).contains(note), (1...127).contains(velocity) else { return [] }
        let key = Key(channel:channel,note:note)
        let old = notes[key] ?? .init(velocity:0,keyDownCount:0)
        let count = old.keyDownCount == Int.max ? Int.max : old.keyDownCount+1
        let effective = old.keyDownCount == 0 ? velocity : max(old.velocity,velocity)
        notes[key] = .init(velocity:effective,keyDownCount:count)
        return [.init(.init(.note,channel:channel,number:note),value:effective)]
    }
    public mutating func noteOff(channel: Int, note: Int) -> [SensorCommand] {
        let key = Key(channel:channel,note:note)
        guard var state = notes[key], state.keyDownCount > 0 else { return [] }
        state.keyDownCount -= 1
        if state.keyDownCount > 0 || sustained.contains(channel) { notes[key] = state; return [] }
        notes.removeValue(forKey:key)
        return [off(key)]
    }
    private func off(_ key: Key) -> SensorCommand {
        .init(.init(.note,channel:key.channel,number:key.note),value:0)
    }
    private mutating func remove(channel: Int, onlyReleased: Bool) -> [SensorCommand] {
        let keys = notes.keys.filter { $0.channel == channel && (!onlyReleased || notes[$0]?.keyDownCount == 0) }
            .sorted { $0.note < $1.note }
        for key in keys { notes.removeValue(forKey:key) }
        return keys.map(off)
    }
    public mutating func control(channel: Int, controller: Int, value: Int) -> [SensorCommand] {
        guard (0...15).contains(channel), (0...127).contains(value) else { return [] }
        switch controller {
        case 64:
            if value >= 64 { sustained.insert(channel); return [] }
            sustained.remove(channel)
            return remove(channel:channel,onlyReleased:true)
        case 120:
            return remove(channel:channel,onlyReleased:false)
        case 123:
            if sustained.contains(channel) {
                for key in Array(notes.keys) where key.channel == channel { notes[key]?.keyDownCount = 0 }
                return []
            }
            return remove(channel:channel,onlyReleased:false)
        case 121:
            sustained.remove(channel)
            return remove(channel:channel,onlyReleased:true)
        default: return []
        }
    }
}

/// RPN 0,0 pitch sensitivity. Selecting NRPN or resetting controllers
/// invalidates the old RPN selection, preventing stray Data Entry updates.
public struct LegacyBendRangeState: Sendable {
    private var msb: Int?
    private var lsb: Int?
    private var semitones = 2
    private var cents = 0
    public init() {}
    public var range: Double { Double(semitones) + Double(cents)/100 }
    public mutating func control(_ controller: Int, value: Int) {
        guard (0...127).contains(value) else { return }
        switch controller {
        case 101: msb = value
        case 100: lsb = value
        case 98,99: msb = nil; lsb = nil
        case 6: if msb == 0 && lsb == 0 { semitones = value }
        case 38: if msb == 0 && lsb == 0 { cents = min(99,value) }
        case 121: self = .init()
        default: break
        }
    }
}
