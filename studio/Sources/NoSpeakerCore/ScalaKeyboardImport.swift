import Foundation

/// Deliberately bounded, offline octave-periodic Scala import. No file I/O,
/// native ports, channel allocation or implicit equal-tempered fallback.
public enum ScalaKeyboardImport {
    public enum Failure: Error, Equatable, Sendable {
        case malformed, unsupported
    }
    public struct Scale: Equatable, Sendable {
        public let name: String
        public let degrees: [Double] // includes 0, excludes terminal octave
    }
    public struct Mapping: Equatable, Sendable {
        public let first: Int
        public let last: Int
        public let middle: Int
        public let reference: Int
        public let referenceHz: Double
        public let entries: [Int?] // empty means consecutive degrees
        public let period: Int

        /// Nil denotes an unmapped or out-of-range physical key.
        public func step(_ note: Int) -> Int? {
            guard (first...last).contains(note) else { return nil }
            let delta = note - middle
            guard !entries.isEmpty else { return delta }
            let slot = ((delta % entries.count) + entries.count) % entries.count
            return entries[slot].map { ((delta - slot) / entries.count) * period + $0 }
        }
    }
    private static func lines(_ text: String) throws -> [String] {
        guard text.utf8.count <= 16_384 else { throw Failure.unsupported }
        let rows = text.split(whereSeparator: \.isNewline).compactMap { raw -> String? in
            let line = raw.prefix(while: { $0 != "!" }).trimmingCharacters(in: .whitespaces)
            return line.isEmpty ? nil : line
        }
        guard rows.allSatisfy({ $0.utf8.count <= 256 && !$0.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) }) else { throw Failure.malformed }
        return rows
    }
    private static func integer(_ s: String) -> Int? {
        guard !s.isEmpty, s.utf8.allSatisfy({ (48...57).contains($0) }) else { return nil }
        return Int(s)
    }
    private static func decimal(_ s: String) -> Double? {
        guard s.utf8.contains(where: { (48...57).contains($0) }),
              s.utf8.allSatisfy({ (48...57).contains($0) || $0 == 46 }),
              let n = Double(s), n.isFinite else { return nil }
        return n
    }
    private static func cents(_ s: String) -> Double? {
        if s.contains(".") { return decimal(s) }
        let pieces = s.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard (1...2).contains(pieces.count), let a = integer(pieces[0]), (1...1_000_000_000).contains(a) else { return nil }
        let b = pieces.count == 2 ? integer(pieces[1]) : 1
        guard let b, (1...1_000_000_000).contains(b) else { return nil }
        return 1200 * log2(Double(a) / Double(b))
    }
    public static func scale(_ text: String) throws -> Scale {
        let rows = try lines(text)
        guard rows.count >= 2, let n = integer(rows[1]), rows[0].utf8.count <= 64 else { throw Failure.malformed }
        guard (2...128).contains(n) else { throw Failure.unsupported }
        guard rows.count == n + 2 else { throw Failure.malformed }
        let pitches = rows.dropFirst(2).compactMap(cents)
        guard pitches.count == n, pitches[0] > 0,
              zip(pitches, pitches.dropFirst()).allSatisfy({ $0 < $1 }) else { throw Failure.malformed }
        // Exact octave only; never silently normalize a non-octave period.
        guard pitches.last == 1200 else { throw Failure.unsupported }
        return Scale(name: rows[0], degrees: [0] + pitches.dropLast())
    }
    public static func mapping(_ text: String, scale: Scale) throws -> Mapping {
        let rows = try lines(text)
        guard rows.count >= 7,
              let size = integer(rows[0]), let first = integer(rows[1]),
              let last = integer(rows[2]), let middle = integer(rows[3]),
              let reference = integer(rows[4]), let hz = decimal(rows[5]),
              let period = integer(rows[6]) else { throw Failure.malformed }
        guard (0...128).contains(size), period == scale.degrees.count else { throw Failure.unsupported }
        guard rows.count == 7 + size, (0...127).contains(first), (first...127).contains(last),
              (0...127).contains(middle), (first...last).contains(reference),
              (1...20_000).contains(hz) else { throw Failure.malformed }
        var entries: [Int?] = []
        for row in rows.dropFirst(7) {
            if row == "x" || row == "X" { entries.append(nil); continue }
            guard let degree = integer(row), degree < period else { throw Failure.unsupported }
            entries.append(degree)
        }
        let map = Mapping(first: first, last: last, middle: middle, reference: reference,
                          referenceHz: hz, entries: entries, period: period)
        guard map.step(reference) != nil else { throw Failure.malformed }
        return map
    }
    /// Derive the root from the KBM reference step, then use the existing
    /// bounded keyboard engine. Reference outside its representable domain
    /// fails closed instead of retuning to an approximate A4.
    public static func tuning(scale: Scale, mapping: Mapping) throws -> MicrotonalKeyboardTuning {
        guard mapping.period == scale.degrees.count, let step = mapping.step(mapping.reference) else { throw Failure.malformed }
        let count = scale.degrees.count
        let degree = ((step % count) + count) % count
        let cents = Double((step - degree) / count) * 1200 + scale.degrees[degree]
        let rootHz = mapping.referenceHz * pow(2, -cents / 1200)
        let midi = 69 + 12 * log2(rootHz / 440)
        guard midi.isFinite, (0...127).contains(midi) else { throw Failure.unsupported }
        let anchor = Int(midi.rounded())
        let a4 = rootHz * pow(2, Double(69 - anchor) / 12)
        guard let tuning = MicrotonalKeyboardTuning(degrees: scale.degrees, rootMIDI: anchor, referenceA4: a4),
              let ref = tuning.pitch(step: step), abs(ref.frequency / mapping.referenceHz - 1) < 1e-10 else { throw Failure.unsupported }
        return tuning
    }
}
