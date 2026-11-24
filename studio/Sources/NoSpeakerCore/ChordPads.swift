import Foundation

/// Built-in automatic chord scales use 12-tone equal temperament.
/// Makam-inspired pitch collections are arranging aids, not makam tuning or seyir.
public enum ChordScale: String, Codable, CaseIterable, Identifiable, Sendable {
    case major = "Major"
    case naturalMinor = "Natural Minor"
    case harmonicMinor = "Harmonic Minor"
    case melodicMinor = "Melodic Minor (ascending)"
    case dorian = "Dorian"
    case phrygian = "Phrygian"
    case lydian = "Lydian"
    case mixolydian = "Mixolydian"
    case locrian = "Locrian"
    case majorPentatonic = "Major Pentatonic"
    case minorPentatonic = "Minor Pentatonic"
    case blues = "Blues"
    case hicaz = "Hicaz-inspired (12-TET)"
    case nihavend = "Nihavend-inspired (12-TET)"
    case kurdi = "Kurdi-inspired (12-TET)"
    case hicazkar = "Hicazkar-inspired (12-TET)"

    public var id: String { rawValue }
    public var intervals: [Int] {
        switch self {
        case .major: [0,2,4,5,7,9,11]
        case .naturalMinor, .nihavend: [0,2,3,5,7,8,10]
        case .harmonicMinor: [0,2,3,5,7,8,11]
        case .melodicMinor: [0,2,3,5,7,9,11]
        case .dorian: [0,2,3,5,7,9,10]
        case .phrygian, .kurdi: [0,1,3,5,7,8,10]
        case .lydian: [0,2,4,6,7,9,11]
        case .mixolydian: [0,2,4,5,7,9,10]
        case .locrian: [0,1,3,5,6,8,10]
        case .majorPentatonic: [0,2,4,7,9]
        case .minorPentatonic: [0,3,5,7,10]
        case .blues: [0,3,5,6,7,10]
        case .hicaz: [0,1,4,5,7,9,10]
        case .hicazkar: [0,1,4,5,7,8,11]
        }
    }
}

public enum ChordStack: String, Codable, CaseIterable, Identifiable, Sendable {
    case triads = "Scale triads"
    case sevenths = "Scale sevenths"
    case ninths = "Scale ninths"
    case quartal = "Scale fourths"
    case octaves = "Octaves"
    public var id: String { rawValue }
    var steps: [Int] {
        switch self {
        case .triads: [0,2,4]
        case .sevenths: [0,2,4,6]
        case .ninths: [0,2,4,6,8]
        case .quartal: [0,3,6]
        case .octaves: [0]
        }
    }
}

public struct ChordPad: Codable, Equatable, Sendable {
    public var name: String
    public var notes: [Int]
    public init(name: String, notes: [Int]) {
        self.name = name
        self.notes = notes
    }
    public var isValid: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        name.utf8.count <= 64 &&
        !name.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) } &&
        (1...8).contains(notes.count) && notes.allSatisfy { (0...127).contains($0) } &&
        Set(notes).count == notes.count
    }
    /// Accept MIDI numbers or scientific pitch names, including flats and C-1.
    public static func parseNotes(_ text: String) -> [Int]? {
        guard text.utf8.count <= 256 else { return nil }
        let tokens = text.split(whereSeparator: { $0 == "," || $0.isWhitespace })
        guard (1...8).contains(tokens.count) else { return nil }
        let pitchClasses = ["C":0,"C#":1,"DB":1,"D":2,"D#":3,"EB":3,"E":4,
                            "F":5,"F#":6,"GB":6,"G":7,"G#":8,"AB":8,"A":9,"A#":10,"BB":10,"B":11]
        var result: [Int] = []
        for token in tokens {
            let value: Int
            if let number = Int(token) { value = number }
            else {
                let name = String(token).uppercased()
                guard let start = name.firstIndex(where: { $0 == "-" || $0.isNumber }),
                      let pitch = pitchClasses[String(name[..<start])],
                      let octave = Int(name[start...]), (-1...9).contains(octave) else { return nil }
                value = (octave + 1) * 12 + pitch
            }
            guard (0...127).contains(value), !result.contains(value) else { return nil }
            result.append(value)
        }
        return result
    }

    public var noteNames: String {
        notes.map { (try? MusicTheory.noteName(midi: $0)) ?? String($0) }.joined(separator: " ")
    }
}

/// Custom slots use absolute MIDI notes and survive scale/root changes.
/// Resetting one override restores the generated slot.
public struct ChordBank: Codable, Equatable, Sendable {
    public var root = 60
    public var scale: ChordScale = .major
    /// Optional for backward compatibility; nil selects the built-in scale.
    public var customScale: CustomScale?
    public var scaleName: String { customScale?.name ?? scale.rawValue }
    public var centsByPitchClass: [Int: Int] { customScale?.offsetsByPitchClass(root: root) ?? [:] }
    public var permitsSelectedOutput: Bool {
        guard let customScale, customScale.isMicrotonal, effectiveOutput.sendsMIDI else { return true }
        return customScale.allowEqualTemperedMIDI
    }
    public var stack: ChordStack = .triads
    public var inversion = 0
    public var channel = 1
    public var velocity = 96
    public var gateMS = 400
    public var latch = false
    public var overrides: [Int: ChordPad] = [:]
    /// Optional for backward-compatible decoding of existing saved banks.
    public var output: MusicalOutput?
    public var effectiveOutput: MusicalOutput { output ?? .midi }
    public static let padCount = 8
    public init() {}

    public var isValid: Bool {
        (36...71).contains(root) && (0...2).contains(inversion) &&
        (1...16).contains(channel) && (1...127).contains(velocity) &&
        (100...2000).contains(gateMS) && (customScale?.isValid ?? true) &&
        overrides.count <= Self.padCount &&
        overrides.allSatisfy { (0..<Self.padCount).contains($0.key) && $0.value.isValid }
    }

    public func pad(at index: Int) -> ChordPad? {
        guard isValid, (0..<Self.padCount).contains(index) else { return nil }
        if let custom = overrides[index] { return custom }
        let intervals = customScale?.intervals ?? scale.intervals
        func pitch(_ degree: Int) -> Int {
            root + intervals[degree % intervals.count] + 12 * (degree / intervals.count)
        }
        var notes = stack.steps.map { pitch(index + $0) }
        if stack == .octaves { notes.append(notes[0] + 12) }
        let fundamental = notes[0]
        let relative = notes.map { $0 - fundamental }
        let names = ["C","C#","D","D#","E","F","F#","G","G#","A","A#","B"]
        let quality: String
        switch relative {
        case [0,4,7]: quality = ""
        case [0,3,7]: quality = "m"
        case [0,3,6]: quality = "dim"
        case [0,4,8]: quality = "aug"
        case [0,4,7,11]: quality = "maj7"
        case [0,4,7,10]: quality = "7"
        case [0,3,7,10]: quality = "m7"
        case [0,3,7,11]: quality = "m(maj7)"
        case [0,3,6,10]: quality = "m7b5"
        case [0,3,6,9]: quality = "dim7"
        default: quality = " [" + relative.map(String.init).joined(separator: ",") + "]"
        }
        for _ in 0..<min(inversion, notes.count - 1) {
            notes.sort()
            var moved = notes.removeFirst() + 12
            while notes.contains(moved) { moved += 12 }
            notes.append(moved)
        }
        notes.sort()
        guard notes.allSatisfy({ (0...127).contains($0) }), Set(notes).count == notes.count else { return nil }
        // Chord quality names describe the nominal MIDI voicing, not the
        // exact acoustic quality of a microtonally displaced interval.
        return ChordPad(name: names[fundamental % 12] + quality, notes: notes)
    }
}

/// Independent chord pad ownership. Output is note-on/off data only; caller
/// must deliver commands to an isolated endpoint and handle delivery failures.
public struct ChordPadState: Sendable {
    private var held: [Int: [SensorDestination]] = [:]
    private var counts: [SensorDestination: Int] = [:]
    public init() {}
    public var activeSlots: Set<Int> { Set(held.keys) }
    public var activeNotes: [Int] { Set(counts.keys.map(\.number)).sorted() }

    public mutating func press(slot: Int, pad: ChordPad, channel: Int, velocity: Int) -> [SensorCommand] {
        guard (0..<ChordBank.padCount).contains(slot), held[slot] == nil,
              pad.isValid, (0...15).contains(channel), (1...127).contains(velocity) else { return [] }
        let keys = pad.notes.sorted().map { SensorDestination(.note, channel: channel, number: $0) }
        held[slot] = keys
        var result: [SensorCommand] = []
        for key in keys {
            let count = counts[key, default: 0]
            counts[key] = count + 1
            if count == 0 { result.append(.init(key, value: velocity)) }
        }
        return result
    }

    public mutating func release(slot: Int) -> [SensorCommand] {
        guard let keys = held.removeValue(forKey: slot) else { return [] }
        var result: [SensorCommand] = []
        for key in keys {
            let count = counts[key, default: 0]
            if count <= 1 {
                counts.removeValue(forKey: key)
                result.append(.init(key, value: 0))
            } else { counts[key] = count - 1 }
        }
        return result
    }

    public mutating func releaseAll() -> [SensorCommand] {
        let keys = held.keys.sorted()
        return keys.flatMap { release(slot: $0) }
    }
}
