import Foundation

/// Shared output choice for any note-producing instrument. Pure MIDI does not
/// require Force Touch hardware. Other modules may adopt this incrementally.
public enum MusicalOutput: String, Codable, CaseIterable, Identifiable, Sendable {
    case midi = "MIDI"
    case haptic = "Trackpad"
    case both = "Both"
    public var id: String { rawValue }
    public var sendsMIDI: Bool { self != .haptic }
    public var sendsHaptics: Bool { self != .midi }
}

/// A single actuator cannot independently reproduce unlimited polyphony.
/// Preserve pitch classes by octave folding, deduplicate resulting pitches,
/// and select at most six distinct pitches with deterministic priority.
public enum NoteHapticRenderer {
    public static func frame(notes: [Int], velocity: Int,
                             safety: HapticSafetyPolicy = .init(),
                             semitoneOffset: Double = 0, expression: Double = 1,
                             centsByPitchClass: [Int: Int] = [:]) -> HapticFrame? {
        guard (1...127).contains(velocity), semitoneOffset.isFinite,
              (-24...24).contains(semitoneOffset), expression.isFinite, (0...1).contains(expression),
              safety.minFrequencyHz.isFinite, safety.maxFrequencyHz.isFinite,
              safety.minFrequencyHz > 0, safety.maxFrequencyHz >= safety.minFrequencyHz,
              safety.maxTonesPerFrame > 0, centsByPitchClass.count <= 12,
              centsByPitchClass.allSatisfy({ (0...11).contains($0.key) && (-49...49).contains($0.value) }) else { return nil }
        func ratio(for note: Int) -> Double {
            pow(2, (semitoneOffset + Double(centsByPitchClass[note % 12] ?? 0) / 100) / 12)
        }
        var pitches: [Int] = []
        for original in Set(notes.filter { (0...127).contains($0) }).sorted() {
            var note = original
            guard var hz = try? MusicTheory.frequency(midi: note) else { continue }
            hz *= ratio(for: original)
            while hz < safety.minFrequencyHz && note <= 115 { note += 12; hz *= 2 }
            while hz > safety.maxFrequencyHz && note >= 12 { note -= 12; hz /= 2 }
            guard (safety.minFrequencyHz...safety.maxFrequencyHz).contains(hz),
                  !pitches.contains(note) else { continue }
            pitches.append(note)
        }
        // Retain the lowest audible pitch and then progressively higher tones.
        let selected = pitches.sorted().prefix(min(6, safety.maxTonesPerFrame))
        let tones = selected.compactMap { note -> HapticTone? in
            guard let hz = try? MusicTheory.frequency(midi: note) else { return nil }
            return .init(frequencyHz: hz * ratio(for: note), amplitude: 1 / Double(selected.count))
        }
        guard !tones.isEmpty else { return nil }
        return safety.clamp(.init(tones: tones, durationMS: 18,
                                  level: Double(velocity) / 127 * expression))
    }
}
