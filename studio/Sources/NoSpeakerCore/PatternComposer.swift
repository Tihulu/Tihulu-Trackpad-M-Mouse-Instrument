import Foundation

public enum DrumComposerStyle: String, Codable, CaseIterable, Identifiable, Sendable {
    case rock = "Rock"
    case house = "House"
    case hipHop = "Hip-Hop"
    case funk = "Funk"
    public var id: String { rawValue }
}

public enum NoteComposerStyle: String, Codable, CaseIterable, Identifiable, Sendable {
    case melody = "Melody"
    case bass = "Bass"
    case arpeggio = "Arpeggio"
    public var id: String { rawValue }
}

/// Bounded, deterministic symbolic composition, not a trained ML model.
/// Generates editable musical data only and never starts playback.
public enum PatternComposer {
    private struct Random {
        var state: UInt64
        mutating func next(_ bound: Int) -> Int {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Int((state >> 32) % UInt64(max(1, bound)))
        }
    }

    public static func drums(style: DrumComposerStyle, complexity: Int,
                             fills: Bool, seed: Int) -> Set<String> {
        guard (0...100).contains(complexity), (1...9999).contains(seed) else { return [] }
        var rng = Random(state: UInt64(seed))
        var result: Set<String> = []
        func hit(_ voice: DrumVoice, _ step: Int) {
            guard (0..<16).contains(step) else { return }
            // Closed and open hats never share an onset.
            if voice == .openHat { result.remove("closedHat:" + String(step)) }
            if voice == .closedHat && result.contains("openHat:" + String(step)) { return }
            result.insert(voice.rawValue + ":" + String(step))
        }
        let kicks: [Int]
        let snares: [Int]
        let hats: [Int]
        switch style {
        case .rock: kicks = [0,8]; snares = [4,12]; hats = [0,2,4,6,8,10,12,14]
        case .house: kicks = [0,4,8,12]; snares = [4,12]; hats = [2,6,10,14]
        case .hipHop: kicks = [0,7,10]; snares = [4,12]; hats = [0,4,8,12]
        case .funk: kicks = [0,3,8,10]; snares = [4,12]; hats = [0,2,4,6,8,10,12,14]
        }
        for s in kicks { hit(.kick,s) }
        for s in snares { hit(style == .house ? .clap : .snare,s) }
        for s in hats { hit(style == .house ? .openHat : .closedHat,s) }
        for step in [1,3,5,7,9,11,13,15] {
            if rng.next(100) < complexity / 2 { hit(.closedHat,step) }
        }
        for step in [2,6,11,14] {
            if rng.next(100) < complexity / 3 { hit(.kick,step) }
        }
        if complexity >= 60 && style != .house { hit(.openHat,14) }
        if fills {
            hit(.tom,14)
            if complexity >= 35 { hit(.tom,15) }
            if complexity >= 75 { hit(.snare,13) }
        }
        return result
    }

    public static func notes(bank: ChordBank, slot: Int, style: NoteComposerStyle,
                             complexity: Int, seed: Int) -> [Int?]? {
        guard bank.isValid, (0...100).contains(complexity), (1...9999).contains(seed),
              let pad = bank.pad(at: slot) else { return nil }
        let degrees = bank.customScale?.intervals ?? bank.scale.intervals
        let scaleClasses = Set(degrees.map { (bank.root + $0) % 12 })
        let chordClasses = Set(pad.notes.map { $0 % 12 })
        let range = style == .bass ? 36...59 : 60...83
        let allowed = range.filter { scaleClasses.contains($0 % 12) || chordClasses.contains($0 % 12) }
        let chord = allowed.filter { chordClasses.contains($0 % 12) }
        guard !allowed.isEmpty, !chord.isEmpty else { return nil }
        var rng = Random(state: UInt64(seed))
        var result = Array<Int?>(repeating: nil, count: 16)
        let anchor = chord.min(by: { abs($0 - (style == .bass ? 43 : 67)) <
                                     abs($1 - (style == .bass ? 43 : 67)) }) ?? chord[0]
        var last = anchor
        var arpIndex = 0
        for i in 0..<16 {
            let strong = i % 4 == 0
            if !strong && rng.next(100) >= complexity { continue }
            let note: Int
            switch style {
            case .arpeggio:
                note = chord[arpIndex % chord.count]
                arpIndex += 1
            case .bass:
                if strong { note = chord.min(by: { abs($0 - anchor) < abs($1 - anchor) }) ?? anchor }
                else { note = chord[rng.next(chord.count)] }
            case .melody:
                let pool = strong ? chord : allowed
                let close = pool.filter { abs($0 - last) <= 5 }
                let candidates = close.isEmpty ? pool : close
                note = i == 0 ? anchor : candidates[rng.next(candidates.count)]
            }
            result[i] = note
            last = note
        }
        return result
    }
}
