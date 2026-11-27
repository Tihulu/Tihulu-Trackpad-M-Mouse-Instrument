import Foundation

/// Offline, nominal-pitch generation. Never starts playback or changes a take.
public enum MelodicPatternGenerator {
    public enum Role: String, Codable, CaseIterable, Sendable { case bass, solo }
    public enum Genre: String, Codable, CaseIterable, Sendable {
        case funk, rock, blues, jazz, pop, disco, hipHopTrap, houseTechno, reggae, metal, latin
    }
    public enum Scale: String, Codable, CaseIterable, Sendable {
        case major, minor, dorian, mixolydian, majorPentatonic, minorPentatonic, blues, phrygian, harmonicMinor
        public var intervals: [Int] {
            switch self {
            case .major: [0, 2, 4, 5, 7, 9, 11]
            case .minor: [0, 2, 3, 5, 7, 8, 10]
            case .dorian: [0, 2, 3, 5, 7, 9, 10]
            case .mixolydian: [0, 2, 4, 5, 7, 9, 10]
            case .majorPentatonic: [0, 2, 4, 7, 9]
            case .minorPentatonic: [0, 3, 5, 7, 10]
            case .blues: [0, 3, 5, 6, 7, 10]
            case .phrygian: [0, 1, 3, 5, 7, 8, 10]
            case .harmonicMinor: [0, 2, 3, 5, 7, 8, 11]
            }
        }
    }
    public struct Configuration: Codable, Equatable, Sendable {
        public var role: Role = .bass
        public var genre: Genre = .funk
        public var root = 0 // pitch class, C = 0
        public var scale: Scale = .minor
        public var bpm = 120.0
        public var bars = 4
        public var low = 36
        public var high = 60
        public var complexity = 50
        public var density = 50
        public var syncopation = 50
        public var variation = 30
        public var gate = 0.8
        public var velocity = 0.85
        public var seed: UInt64 = 1
        public init() {}
    }
    public enum ValidationError: Error, Equatable { case invalidConfiguration, emptyRegister }

    private struct Profile {
        let rhythm: [Int]
        let bass: [Int]
        let solo: [Int]
    }
    private static func profile(_ genre: Genre) -> Profile {
        switch genre {
        case .funk: .init(rhythm: [0, 3, 6, 7, 10, 12, 15, 8], bass: [0, 12, 7, 0, 10, 7], solo: [0, 3, 5, 7, 10, 7])
        case .rock: .init(rhythm: [0, 4, 8, 12, 2, 6, 10, 14], bass: [0, 0, 7, 0, 12, 7], solo: [0, 7, 5, 3, 7, 12])
        case .blues: .init(rhythm: [0, 4, 8, 12, 3, 7, 11, 15], bass: [0, 4, 7, 9, 10, 9, 7, 4], solo: [0, 3, 5, 6, 7, 10, 7, 3])
        case .jazz: .init(rhythm: [0, 4, 8, 12, 6, 14, 2, 10], bass: [0, 4, 7, 11, 12, 9, 5, 2], solo: [0, 4, 7, 11, 9, 7, 5, 2])
        case .pop: .init(rhythm: [0, 8, 4, 12, 2, 10, 6, 14], bass: [0, 0, 7, 12], solo: [0, 2, 4, 7, 4, 2])
        case .disco: .init(rhythm: [0, 2, 4, 6, 8, 10, 12, 14], bass: [0, 12, 0, 12, 7, 12], solo: [0, 7, 12, 7, 9, 4])
        case .hipHopTrap: .init(rhythm: [0, 7, 10, 14, 3, 8, 11, 15], bass: [0, 0, -5, 0, 7, 0], solo: [0, 3, 0, 7, 5, 3])
        case .houseTechno: .init(rhythm: [2, 6, 10, 14, 0, 4, 8, 12], bass: [0, 0, 0, 7, 0, 12], solo: [0, 7, 0, 7, 3, 5])
        case .reggae: .init(rhythm: [0, 6, 10, 12, 3, 8, 14, 15], bass: [0, 7, 0, 5, 7, 0], solo: [0, 2, 7, 5, 4, 2])
        case .metal: .init(rhythm: [0, 2, 3, 4, 6, 7, 8, 12], bass: [0, 0, 0, 7, 0, 1, 0, 12], solo: [0, 1, 3, 7, 12, 10, 7, 3])
        case .latin: .init(rhythm: [0, 6, 10, 14, 3, 7, 12, 15], bass: [0, 7, 12, 7, 5, 7], solo: [0, 4, 7, 9, 7, 5, 2])
        }
    }

    private struct Random {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9e3779b97f4a7c15
            var z = state
            z = (z ^ (z >> 30)) &* 0xbf58476d1ce4e5b9
            z = (z ^ (z >> 27)) &* 0x94d049bb133111eb
            return z ^ (z >> 31)
        }
        mutating func draw(_ upper: Int) -> Int { Int(next() % UInt64(upper)) }
        mutating func id() -> UUID {
            let a = next(), b = next()
            func byte(_ value: UInt64, _ shift: Int) -> UInt8 { UInt8(truncatingIfNeeded: value >> shift) }
            return UUID(uuid: (byte(a, 56), byte(a, 48), byte(a, 40), byte(a, 32), byte(a, 24), byte(a, 16),
                               (byte(a, 8) & 15) | 64, byte(a, 0), (byte(b, 56) & 63) | 128, byte(b, 48),
                               byte(b, 40), byte(b, 32), byte(b, 24), byte(b, 16), byte(b, 8), byte(b, 0)))
        }
    }

    public static func generate(_ c: Configuration) throws -> NoteSequence {
        guard (0...11).contains(c.root), c.bpm.isFinite, (20...300).contains(c.bpm),
              (1...16).contains(c.bars), (0...127).contains(c.low), (0...127).contains(c.high), c.low <= c.high,
              [c.complexity, c.density, c.syncopation, c.variation].allSatisfy({ (0...100).contains($0) }),
              c.gate.isFinite, (0.05...1).contains(c.gate), c.velocity.isFinite, (0.01...1).contains(c.velocity)
        else { throw ValidationError.invalidConfiguration }
        let pitches = (c.low...c.high).filter { c.scale.intervals.contains(($0 % 12 - c.root + 12) % 12) }
        guard !pitches.isEmpty else { throw ValidationError.emptyRegister }
        func nearest(_ target: Int, in pool: [Int]) -> Int {
            pool.min { abs($0 - target) < abs($1 - target) }! // nonempty, ascending; ties choose lower
        }
        let roots = pitches.filter { $0 % 12 == c.root }
        let anchor = nearest(c.low + (c.high - c.low) / (c.role == .bass ? 3 : 2), in: roots.isEmpty ? pitches : roots)
        let style = profile(c.genre)
        let motif = c.role == .bass ? style.bass : style.solo
        let count = 1 + c.density * 15 / 100
        var random = Random(state: c.seed)
        var prior: [(index: Int, pitch: Int)] = []
        var steps: [NoteStep] = []
        for bar in 0..<c.bars {
            var phrase: [(index: Int, pitch: Int)] = []
            if bar > 0 && random.draw(100) >= c.variation {
                phrase = prior
            } else {
                var scores: [(index: Int, score: Int)] = []
                for index in 0..<16 {
                    let priority = style.rhythm.firstIndex(of: index).map { 160 - $0 * 14 } ?? 0
                    let sync = index % 4 == 0 ? 100 - c.syncopation : c.syncopation
                    scores.append((index, priority + sync + random.draw(c.complexity + 1)))
                }
                let selected = scores.sorted { $0.score == $1.score ? $0.index < $1.index : $0.score > $1.score }
                    .prefix(count).map(\.index).sorted()
                for (position, index) in selected.enumerated() {
                    let template = motif[position % motif.count]
                    let useMotif = position > 0 && random.draw(100) < c.complexity
                    let offset = useMotif ? template : (c.role == .bass ? 0 : motif[min(position, 1)])
                    let embellish = useMotif && random.draw(100) < c.complexity / 3 ? random.draw(5) - 2 : 0
                    phrase.append((index, nearest(anchor + offset + embellish, in: pitches)))
                }
            }
            prior = phrase
            for (position, item) in phrase.enumerated() {
                let cadence = c.role == .solo && bar == c.bars - 1 && position == phrase.count - 1
                let velocity = min(1, c.velocity * (item.index % 4 == 0 ? 1.0 : 0.82))
                steps.append(.init(id: random.id(), index: bar * 16 + item.index, midi: cadence ? anchor : item.pitch,
                                   velocity: velocity, gate: c.gate))
            }
        }
        let sequence = NoteSequence(bpm: c.bpm, stepsPerBeat: 4, length: c.bars * 16, steps: steps)
        _ = try MIDIClip.melody(sequence)
        return sequence
    }
}
