import Foundation

/// Dedicated MPE lower-zone note allocation for a chord bank. Member
/// channels 2–16 (zero-based 1–15) are reserved exclusively for this source.
/// No note stealing, shared-channel bends, or silent 12-TET fallback.
/// The receiver must honor MPE and the configured +/-2 semitone range.
public struct ChordMPEState: Sendable {
    private var members: [SensorDestination: Int] = [:]
    public init() {}
    public var activeCount: Int { members.count }

    public static func configuration() -> [SensorCommand] {
        func rpn(channel: Int, number: Int, value: Int, fine: Bool = false) -> [SensorCommand] {
            var pairs = [(101,0),(100,number),(6,value)]
            if fine { pairs.append((38,0)) }
            pairs += [(101,127),(100,127)]
            return pairs.map { .init(.init(.controlChange, channel: channel, number: $0.0), value: $0.1) }
        }
        // Disable upper zone before assigning the whole lower zone.
        var result = rpn(channel: 15, number: 6, value: 0)
        result += rpn(channel: 0, number: 6, value: 15)
        for channel in 0...15 {
            result += rpn(channel: channel, number: 0, value: 2, fine: true)
            result.append(.init(.init(.pitchBend, channel: channel), value: 8192))
        }
        return result
    }

    public static func bend(cents: Int) -> Int? {
        guard (-49...49).contains(cents) else { return nil }
        return 8192 + Int((Double(cents) * 8192 / 200).rounded())
    }

    /// Transform one logical note command. Commit only if valid. Logical
    /// refcounting is supplied by ChordPadState. The caller tracks attempted
    /// physical Note Ons independently and releases them on delivery failure.
    public mutating func route(_ command: SensorCommand,
                               centsByPitchClass: [Int: Int]) -> [SensorCommand]? {
        let key = command.destination
        guard key.isValid, key.kind == .note, (0...127).contains(command.value) else { return nil }
        if command.value == 0 {
            guard let channel = members.removeValue(forKey: key) else { return [] }
            // Leave the bend unchanged for the release tail. Reinitialize it
            // before a channel's next Note On.
            return [.init(.init(.note, channel: channel, number: key.number), value: 0)]
        }
        if members[key] != nil { return [] }
        guard let channel = (1...15).first(where: { !members.values.contains($0) }),
              let bend = Self.bend(cents: centsByPitchClass[key.number % 12] ?? 0) else { return nil }
        members[key] = channel
        return [
            .init(.init(.pitchBend, channel: channel), value: bend),
            .init(.init(.note, channel: channel, number: key.number), value: command.value)
        ]
    }

    /// Only call after the physical outstanding-note ledger is empty.
    public mutating func clearAfterRelease() { members.removeAll(keepingCapacity: true) }
}
