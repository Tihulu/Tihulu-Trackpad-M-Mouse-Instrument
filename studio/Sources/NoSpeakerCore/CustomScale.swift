import Foundation

/// An octave-repeating, root-relative scale on distinct MIDI pitch classes.
/// Each selected degree may be displaced by up to 49 cents. This is a
/// practical custom intonation editor, not a complete makam/seyir model,
/// arbitrary EDO mapping or per-note MIDI tuning protocol.
public struct CustomScale: Codable, Equatable, Sendable {
    public var name = "Custom scale"
    public var intervals = [0,2,4,5,7,9,11]
    public var centOffsets: [Int: Int] = [:]
    public var allowEqualTemperedMIDI = false
    public init() {}

    public var isValid: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        name.utf8.count <= 64 &&
        !name.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) } &&
        (2...12).contains(intervals.count) &&
        intervals.first == 0 && intervals == Array(Set(intervals)).sorted() &&
        intervals.allSatisfy { (0...11).contains($0) } &&
        centOffsets.count <= 11 &&
        centOffsets.allSatisfy { intervals.contains($0.key) && $0.key != 0 && (-49...49).contains($0.value) }
    }

    public var isMicrotonal: Bool { centOffsets.values.contains { $0 != 0 } }

    public func offsetsByPitchClass(root: Int) -> [Int: Int] {
        guard isValid, (0...127).contains(root) else { return [:] }
        return Dictionary(uniqueKeysWithValues: centOffsets.map { ((root + $0.key) % 12, $0.value) })
    }
}
