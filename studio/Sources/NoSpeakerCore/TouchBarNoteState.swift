import Foundation

/// Local Touch Bar notes use independent source ownership. Sustain is
/// implemented as note ownership, so local and dedicated MIDI output agree.
public enum TouchBarNoteOwner: String, Hashable, Sendable {
    case screenPiano, nativePiano, screenRibbon, nativeRibbon
}

public struct TouchBarNoteState: Sendable {
    private struct Key: Hashable, Sendable {
        let note: Int
        let owner: TouchBarNoteOwner
    }
    private var held: Set<Key> = []
    private var sustained: Set<Int> = []
    public private(set) var sustain = false
    public private(set) var bend = 0.0
    public private(set) var expression = 1.0
    public init() {}
    public var notes: [Int] { Set(held.map(\.note)).union(sustained).sorted() }

    public mutating func key(_ note: Int, owner: TouchBarNoteOwner, pressed: Bool,
                             channel: Int, velocity: Int) -> [SensorCommand] {
        guard (0...127).contains(note), (0...15).contains(channel), (1...127).contains(velocity) else { return [] }
        let before = Set(notes)
        let key = Key(note: note, owner: owner)
        if pressed {
            guard held.insert(key).inserted else { return [] }
            sustained.remove(note)
        } else {
            guard held.remove(key) != nil else { return [] }
            if sustain && !held.contains(where: { $0.note == note }) { sustained.insert(note) }
        }
        return diff(before, channel: channel, velocity: velocity)
    }

    public mutating func setSustain(_ active: Bool, channel: Int, velocity: Int) -> [SensorCommand] {
        guard (0...15).contains(channel), (1...127).contains(velocity) else { return [] }
        let before = Set(notes)
        sustain = active
        if !active { sustained.removeAll() }
        return diff(before, channel: channel, velocity: velocity)
    }

    public mutating func setBend(_ normalized: Double) {
        guard normalized.isFinite else { return }
        bend = (min(1, max(0, normalized)) - 0.5) * 24
    }

    public mutating func setExpression(_ normalized: Double) {
        guard normalized.isFinite else { return }
        expression = min(1, max(0, normalized))
    }

    public func frame(velocity: Int) -> HapticFrame? {
        NoteHapticRenderer.frame(notes: notes, velocity: velocity,
                                 semitoneOffset: bend, expression: expression)
    }

    public mutating func reset(channel: Int) -> [SensorCommand] {
        let before = notes
        self = Self()
        guard (0...15).contains(channel) else { return [] }
        return before.map { .init(.init(.note, channel: channel, number: $0), value: 0) }
    }

    private func diff(_ before: Set<Int>, channel: Int, velocity: Int) -> [SensorCommand] {
        let after = Set(notes)
        let off = before.subtracting(after).sorted().map {
            SensorCommand(.init(.note, channel: channel, number: $0), value: 0)
        }
        let on = after.subtracting(before).sorted().map {
            SensorCommand(.init(.note, channel: channel, number: $0), value: velocity)
        }
        return off + on
    }
}
