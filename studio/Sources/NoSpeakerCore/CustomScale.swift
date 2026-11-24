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

    /// Match the existing fret-width convention: width 1 spans two octaves
    /// including the final root, then grow or shrink the number of regions.
    public func mappedMIDINotes(root: Int, zoneWidth: Double) -> [Int] {
        guard isValid, (0...127).contains(root), zoneWidth.isFinite else { return [] }
        let width = min(2.5, max(0.45, zoneWidth))
        let count = max(3, min(32, Int((Double(intervals.count * 2 + 1) / width).rounded())))
        return (0..<count).compactMap { step in
            let note = root + 12 * (step / intervals.count) + intervals[step % intervals.count]
            return note <= 127 ? note : nil
        }
    }

    public func tunedFrequency(midi: Int, root: Int) -> Double? {
        guard isValid, (0...127).contains(root), (0...127).contains(midi),
              let hz = try? MusicTheory.frequency(midi: midi) else { return nil }
        let degree = (midi - root + 144) % 12
        return hz * pow(2, Double(centOffsets[degree] ?? 0) / 1200)
    }

    public func offsetsByPitchClass(root: Int) -> [Int: Int] {
        guard isValid, (0...127).contains(root) else { return [:] }
        return Dictionary(uniqueKeysWithValues: centOffsets.map { ((root + $0.key) % 12, $0.value) })
    }
}
