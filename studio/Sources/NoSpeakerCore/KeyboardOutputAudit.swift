/// Opt-in bounded counters for actual legacy MIDI submissions. No incoming
/// keyboard notes, note numbers, timestamps, or device identifiers retained.
public struct KeyboardOutputAudit: Equatable, Sendable {
    public private(set) var pedal = 0
    public private(set) var notes = 0
    public private(set) var volume = 0
    public private(set) var expression = 0
    public private(set) var pitch = 0
    public private(set) var pressure = 0
    public private(set) var other = 0
    public private(set) var failed = 0
    public private(set) var channelMask:UInt16 = 0
    public private(set) var attempts = 0
    public static let limit = 100_000
    public var saturated:Bool { attempts >= Self.limit }
    public var onlyPedal:Bool { attempts > 0 && pedal == attempts && failed == 0 }
    public init() {}
    public mutating func record(_ m:LegacyGateReleaseDebt.Message,succeeded:Bool) {
        guard !saturated else { return }
        attempts += 1
        if !succeeded { failed += 1 }
        channelMask |= UInt16(1) << (m.status & 15)
        switch m.status & 0xf0 {
        case 0x80,0x90: notes += 1
        case 0xa0,0xd0: pressure += 1
        case 0xe0: pitch += 1
        case 0xb0 where m.data1 == 64: pedal += 1
        case 0xb0 where m.data1 == 7: volume += 1
        case 0xb0 where m.data1 == 11: expression += 1
        default: other += 1
        }
    }
    public var channels:[Int] { (0...15).filter { channelMask & (UInt16(1) << $0) != 0 }.map { $0+1 } }
}
