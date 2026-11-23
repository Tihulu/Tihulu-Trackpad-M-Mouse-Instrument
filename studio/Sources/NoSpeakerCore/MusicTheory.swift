import Foundation

public enum MusicTheoryError: Error, Equatable {
    case invalidNote(String)
    case midiOutOfRange(Int)
}

public enum MusicTheory {
    private static let semitones: [String: Int] = [
        "C": 0, "C#": 1, "DB": 1, "D": 2, "D#": 3, "EB": 3,
        "E": 4, "F": 5, "F#": 6, "GB": 6, "G": 7, "G#": 8,
        "AB": 8, "A": 9, "A#": 10, "BB": 10, "B": 11
    ]

    public static func midiNumber(note: String) throws -> Int {
        let normalized = note.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard normalized.count >= 2 else { throw MusicTheoryError.invalidNote(note) }

        let octaveStart = normalized.lastIndex(where: { $0 == "-" || $0.isNumber })
        guard let octaveStart else { throw MusicTheoryError.invalidNote(note) }
        let name = String(normalized[..<octaveStart])
        let octaveString = String(normalized[octaveStart...])
        guard let semitone = semitones[name], let octave = Int(octaveString) else {
            throw MusicTheoryError.invalidNote(note)
        }

        let midi = (octave + 1) * 12 + semitone
        guard (0...127).contains(midi) else { throw MusicTheoryError.midiOutOfRange(midi) }
        return midi
    }

    public static func frequency(midi: Int) throws -> Double {
        guard (0...127).contains(midi) else { throw MusicTheoryError.midiOutOfRange(midi) }
        return 440.0 * pow(2.0, Double(midi - 69) / 12.0)
    }

    public static func frequency(note: String) throws -> Double {
        try frequency(midi: midiNumber(note: note))
    }

    public static func noteName(midi: Int) throws -> String {
        guard (0...127).contains(midi) else { throw MusicTheoryError.midiOutOfRange(midi) }
        let names = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
        return names[midi % 12] + String(midi / 12 - 1)
    }
}
