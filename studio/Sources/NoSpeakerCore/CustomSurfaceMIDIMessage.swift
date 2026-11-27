import Foundation

/// Exact MIDI 1.0 channel voice bytes for a frozen standard custom-pad plan.
/// Refuse invalid values or unsafe CCs rather than clamp or reinterpret.
public enum CustomSurfaceMIDIMessage {
    public static func bytes(for command: SensorCommand) -> [UInt8]? {
        let d = command.destination, v = command.value
        guard d.isValid else { return nil }
        switch d.kind {
        case .note:
            guard (0...127).contains(v) else { return nil }
            return [UInt8((v == 0 ? 0x80 : 0x90) | d.channel), UInt8(d.number), UInt8(v)]
        case .sustain:
            guard v == 0 || v == 127 else { return nil }
            return [UInt8(0xb0 | d.channel), 64, UInt8(v)]
        case .controlChange:
            guard (0...127).contains(v), HelperCCPolicy.permits(d.number),
                  !(64...69).contains(d.number) else { return nil }
            return [UInt8(0xb0 | d.channel), UInt8(d.number), UInt8(v)]
        case .pitchBend:
            guard (0...16383).contains(v) else { return nil }
            return [UInt8(0xe0 | d.channel), UInt8(v & 127), UInt8(v >> 7)]
        }
    }
}
