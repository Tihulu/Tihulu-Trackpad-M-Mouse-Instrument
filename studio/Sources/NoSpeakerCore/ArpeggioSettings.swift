import Foundation

public enum ArpeggioOrder: String, Codable, CaseIterable, Identifiable, Sendable {
    case ascending = "Up"
    case descending = "Down"
    case alternating = "Up / Down"
    case shuffle = "Shuffle (repeatable)"
    public var id: String { rawValue }
}

public struct ArpeggioSettings: Codable, Equatable, Sendable {
    public var order: ArpeggioOrder = .ascending
    public var notesPerBeat = 4
    public var octaves = 1
    public var seed = 1
    public init() {}
    public var isValid: Bool {
        [1,2,3,4,6,8].contains(notesPerBeat) &&
        (1...3).contains(octaves) && (1...9999).contains(seed)
    }

    /// Resolve absolute MIDI notes once. Keep the supplied voicing rather
    /// than replacing it with pitch classes. Overlapping octaves deduplicate.
    /// Out-of-range transpositions are omitted, never wrapped or clamped.
    public func noteOrder(for pad: ChordPad) -> [Int] {
        guard isValid, pad.isValid else { return [] }
        let notes = Set((0..<octaves).flatMap { octave in
            pad.notes.map { $0 + 12 * octave }.filter { (0...127).contains($0) }
        }).sorted()
        switch order {
        case .ascending: return notes
        case .descending: return Array(notes.reversed())
        case .alternating:
            guard notes.count > 2 else { return notes }
            return notes + Array(notes.dropFirst().dropLast().reversed())
        case .shuffle:
            var result = notes
            var state = UInt64(seed)
            if result.count > 1 {
                for i in stride(from: result.count - 1, through: 1, by: -1) {
                    // Stable seeded shuffle; same saved bank and seed repeat.
                    state = state &* 6364136223846793005 &+ 1442695040888963407
                    let j = Int((state >> 32) % UInt64(i + 1))
                    result.swapAt(i, j)
                }
            }
            return result
        }
    }
}
