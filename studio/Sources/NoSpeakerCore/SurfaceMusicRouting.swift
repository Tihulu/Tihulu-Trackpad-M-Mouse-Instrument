import Foundation

/// Each touch surface can independently play pitched notes or General MIDI percussion.
public enum SurfaceInstrumentMode: String, CaseIterable, Identifiable, Sendable, Codable {
    case melodic = "Melodic"
    case drums = "Drums"
    case chords = "Chord Pads"
    case guitar = "Guitar Pad (Fretted)"
    case fretlessStrings = "String Pad (Fretless)"

    public var isStringSurface: Bool { self == .guitar || self == .fretlessStrings }

    public var id: String { rawValue }
}

/// Routes gestures to the Force Touch motor, to a CoreMIDI destination, or to both.
/// Magic Mouse does not contain a NoSpeaker haptic actuator; the haptic destination
/// is always the connected Force Touch trackpad.
public enum SurfaceOutputRoute: String, CaseIterable, Identifiable, Sendable, Codable {
    case trackpadHaptic = "Trackpad Haptic"
    case midiInstrument = "MIDI Instrument"
    case both = "Both"

    public var id: String { rawValue }

    public var sendsHaptics: Bool { self != .midiInstrument }
    public var sendsMIDI: Bool { self != .trackpadHaptic }
}

public struct DrumPad: Sendable, Equatable, Identifiable {
    public var id: Int { midiNote }
    public var midiNote: Int
    public var name: String

    public init(midiNote: Int, name: String) {
        self.midiNote = midiNote
        self.name = name
    }
}

/// General MIDI percussion note numbers. GM percussion uses MIDI channel 10
/// (zero-based channel index 9). This does not choose a kit in the receiving DAW.
public enum GMDrumPads {
    public static let midiChannel = 9

    public static let standard: [DrumPad] = [
        DrumPad(midiNote: 36, name: "Kick"),
        DrumPad(midiNote: 38, name: "Snare"),
        DrumPad(midiNote: 42, name: "Closed Hat"),
        DrumPad(midiNote: 46, name: "Open Hat"),
        DrumPad(midiNote: 39, name: "Clap"),
        DrumPad(midiNote: 37, name: "Side Stick"),
        DrumPad(midiNote: 45, name: "Low Tom"),
        DrumPad(midiNote: 47, name: "Mid Tom"),
        DrumPad(midiNote: 50, name: "High Tom"),
        DrumPad(midiNote: 49, name: "Crash"),
        DrumPad(midiNote: 51, name: "Ride"),
        DrumPad(midiNote: 56, name: "Cowbell"),
        DrumPad(midiNote: 35, name: "Acoustic Kick"),
        DrumPad(midiNote: 40, name: "Electric Snare"),
        DrumPad(midiNote: 44, name: "Pedal Hat"),
        DrumPad(midiNote: 54, name: "Tambourine")
    ]

    public static func pad(forNormalizedX x: Double, layout: DrumPadLayout) -> DrumPad {
        let pads = layout.pads
        let safeX = x.isFinite ? min(0.999999, max(0, x)) : 0
        return pads[min(pads.count - 1, Int(safeX * Double(pads.count)))]
    }

    public static func name(for midi: Int) -> String? {
        standard.first(where: { $0.midiNote == midi })?.name
    }
}

public enum DrumPadLayout: String, CaseIterable, Identifiable, Sendable, Codable {
    case compact8 = "8 Pads"
    case standard12 = "12 Pads"
    case extended16 = "16 Pads"
    case grid8 = "8 Pads (2 × 4 Grid)"
    case grid12 = "12 Pads (3 × 4 Grid)"
    case grid16 = "16 Pads (4 × 4 Grid)"

    public var id: String { rawValue }

    public var columns: Int {
        switch self {
        case .grid8, .grid12, .grid16: return 4
        case .compact8: return 8
        case .standard12: return 12
        case .extended16: return 16
        }
    }
    public var rows: Int { pads.count / columns }
    public var isGrid: Bool { rows > 1 }

    /// Physical y increases upward; row zero is at the top of the preview.
    public func padIndex(x: Double, y: Double) -> Int? {
        guard x.isFinite, y.isFinite, (0...1).contains(x), (0...1).contains(y) else { return nil }
        let column = min(columns - 1, Int(x * Double(columns)))
        let row = min(rows - 1, Int((1 - y) * Double(rows)))
        return row * columns + column
    }

    public func pad(x: Double, y: Double) -> DrumPad? {
        guard let index = padIndex(x:x,y:y) else { return nil }
        return pads[index]
    }

    /// The caller passes the previous down contact's note only for the same ID.
    public func strikeNote(at candidate: Int, previousDownNote: Int?) -> Int {
        guard isGrid, let previousDownNote,
              pads.contains(where: { $0.midiNote == previousDownNote }) else { return candidate }
        return previousDownNote
    }

    public var pads: [DrumPad] {
        switch self {
        case .compact8, .grid8: return Array(GMDrumPads.standard.prefix(8))
        case .standard12, .grid12: return Array(GMDrumPads.standard.prefix(12))
        case .extended16, .grid16: return GMDrumPads.standard
        }
    }
}

/// Shared channel resolution used by note production and explicit controller
/// target selection. Standard MIDI only; MPE member routing is separate.
public enum SurfaceMIDIChannel {
    public static func melodic(base: Int, hasMIDIDrums: Bool) -> Int {
        let selected = max(0, min(15, base))
        return hasMIDIDrums && selected == GMDrumPads.midiChannel ? 0 : selected
    }

    public static func controlTarget(base: Int, hasMIDIDrums: Bool,
                                     hasMIDIMelody: Bool, isMPE: Bool) -> Int? {
        guard hasMIDIMelody, !isMPE else { return nil }
        return melodic(base: base, hasMIDIDrums: hasMIDIDrums)
    }
}

/// Physical chord grid shares the editable ChordBank's eight slots. A
/// contact holds one slot until release; the bank's timed/latch UI is separate.
public enum PhysicalChordGrid {
    public static func slot(x: Double, y: Double) -> Int? {
        DrumPadLayout.grid8.padIndex(x:x,y:y)
    }

    public static func permitsMIDI(bank: ChordBank, isMPE: Bool, mixedFretless: Bool) -> Bool {
        guard bank.isValid, !isMPE, !mixedFretless else { return false }
        guard let scale = bank.customScale, scale.isMicrotonal else { return true }
        return scale.allowEqualTemperedMIDI
    }
}

/// Reconcile per-contact note sets through the existing shared gate ledger.
/// Add new owners before dropping old ones so a common tone survives a swap.
public struct PhysicalChordGates<Contact: Hashable & Comparable> {
    private var held: [Contact: Set<SensorDestination>] = [:]
    public init() {}
    public var channels: Set<Int> { Set(held.values.flatMap { $0.map(\.channel) }) }
    public var contacts: Set<Contact> { Set(held.keys) }
    public mutating func reconcile<Owner: Hashable>(
        _ desired: [Contact: Set<SensorDestination>], velocity: [Contact: Int],
        ledger: inout LegacyNoteOwners<Owner>, owner: (Contact, SensorDestination) -> Owner
    ) -> [SensorCommand] {
        let proposed = desired.filter { !$0.value.isEmpty }
        // Invalid snapshots fail closed for this source only.
        let next = proposed.allSatisfy({ entry in
            (1...127).contains(velocity[entry.key] ?? 0) &&
            entry.value.allSatisfy { $0.kind == .note && $0.isValid }
        }) ? proposed : [:]
        var result: [SensorCommand] = []
        for contact in next.keys.sorted() {
            let targets = next[contact] ?? []
            for target in targets.subtracting(held[contact] ?? []).sorted(by: Self.less) {
                result += ledger.press(owner(contact,target),channel:target.channel,note:target.number,velocity:velocity[contact] ?? 1)
            }
        }
        for contact in held.keys.sorted() {
            let targets = held[contact] ?? []
            for target in targets.subtracting(next[contact] ?? []).sorted(by: Self.less) {
                result += ledger.release(owner(contact,target))
            }
        }
        held = next
        return result
    }

    /// Same acquire-before-release order as reconcile, but acquire each new
    /// contact/target only while the originating physical receipt is fresh.
    /// On rejection held records exactly the admitted owners, so the caller's
    /// existing scoped retirement does not release an unattempted note.
    public mutating func reconcileAdmitted<Owner: Hashable>(
        _ desired:[Contact:Set<SensorDestination>],velocity:[Contact:Int],
        ledger:inout LegacyNoteOwners<Owner>,owner:(Contact,SensorDestination)->Owner,
        permits:()->Bool,send:(SensorCommand)->Void
    )->Bool {
        let proposed=desired.filter { !$0.value.isEmpty }
        let next=proposed.allSatisfy({ entry in
            (1...127).contains(velocity[entry.key] ?? 0) &&
            entry.value.allSatisfy { $0.kind == .note && $0.isValid }
        }) ? proposed : [:]
        for contact in next.keys.sorted() {
            let targets=next[contact] ?? []
            for target in targets.subtracting(held[contact] ?? []).sorted(by:Self.less) {
                guard ledger.pressAdmitted(owner(contact,target),channel:target.channel,note:target.number,
                    velocity:velocity[contact] ?? 1,permits:permits,send:send) else { return false }
                held[contact,default:[]].insert(target)
            }
        }
        // Ordinary release and retirement are never rejected by the attack fence.
        for contact in held.keys.sorted() {
            for target in (held[contact] ?? []).subtracting(next[contact] ?? []).sorted(by:Self.less) {
                for command in ledger.release(owner(contact,target)) { send(command) }
            }
        }
        held=next
        return permits()
    }

    private static func less(_ lhs: SensorDestination, _ rhs: SensorDestination) -> Bool {
        lhs.channel == rhs.channel ? lhs.number < rhs.number : lhs.channel < rhs.channel
    }
}

/// Shared string/fret geometry. Row zero is the highest-positioned string
/// in the preview; low E is at the bottom, like a conventional tab.
public enum StringTuning: String, CaseIterable, Identifiable, Codable, Sendable {
    case standard = "Guitar · Standard"
    case dropD = "Guitar · Drop D"
    case openG = "Guitar · Open G"
    case bass = "Bass · Standard"
    public var id: String { rawValue }
    public var openNotes: [Int] {
        switch self {
        case .standard: [64,59,55,50,45,40]
        case .dropD: [64,59,55,50,45,38]
        case .openG: [62,59,55,50,43,38]
        case .bass: [43,38,33,28]
        }
    }
}

public enum StringFretDivision: Int, CaseIterable, Identifiable, Codable, Sendable {
    case edo12 = 12
    case edo24 = 24
    case edo53 = 53
    public var id: Int { rawValue }
    public var title: String { "\(rawValue)-EDO" }
}

public struct StringSurfaceLayout: Codable, Equatable, Sendable {
    public var tuning: StringTuning
    public var frets: Int
    /// Optional so archives without custom tuning keep their preset.
    public var customOpenNotes: [Int]?
    public var fretDivision: StringFretDivision?
    /// Absolute offsets from the open string, in integer cents. Custom
    /// intervals override EDO, not the continuous fretless span.
    public var customFretCents: [Int]?
    public init(tuning:StringTuning = .standard, frets:Int = 12, customOpenNotes:[Int]? = nil,
                fretDivision:StringFretDivision? = nil, customFretCents:[Int]? = nil) {
        self.tuning = tuning; self.frets = frets; self.customOpenNotes = customOpenNotes
        self.fretDivision = fretDivision
        self.customFretCents = customFretCents
    }
    public var effectiveDivision: StringFretDivision { fretDivision ?? .edo12 }
    public var isMicrotonal: Bool { customFretCents != nil || effectiveDivision != .edo12 }
    public var openNotes: [Int] { customOpenNotes ?? tuning.openNotes }
    public var isValid: Bool {
        guard (4...24).contains(frets), (3...8).contains(openNotes.count),
              openNotes.allSatisfy({ (0...(127-frets)).contains($0) }) else { return false }
        if let cents = customFretCents {
            guard (2...107).contains(cents.count), cents.first == 0,
                  cents.allSatisfy({ (0...(frets*100)).contains($0) }),
                  zip(cents,cents.dropFirst()).allSatisfy({ $0.0 < $0.1 }) else { return false }
        }
        return true
    }
    public var rows: Int { isValid ? openNotes.count : 0 }
    public var columns: Int { isValid ? (customFretCents?.count ?? (frets * effectiveDivision.rawValue / 12 + 1)) : 0 }
    /// Only complete EDO steps inside the requested span; no out-of-range extra fret.
    public func semitoneOffset(at step:Int) -> Double? {
        guard isValid, (0..<columns).contains(step) else { return nil }
        if let cents = customFretCents { return Double(cents[step])/100 }
        return Double(step) * 12 / Double(effectiveDivision.rawValue)
    }
    public struct Cell: Equatable, Sendable {
        public let string: Int
        public let fret: Int
        public let note: Int
    }
    public func cell(x:Double,y:Double) -> Cell? {
        guard isValid, x.isFinite,y.isFinite,(0...1).contains(x),(0...1).contains(y) else { return nil }
        let string = min(rows-1,Int((1-y)*Double(rows)))
        let fret = min(columns-1,Int(x*Double(columns)))
        guard let offset = semitoneOffset(at:fret) else { return nil }
        return .init(string:string,fret:fret,note:Int((Double(openNotes[string])+offset).rounded()))
    }

    public struct ContinuousCell: Equatable, Sendable {
        public let string: Int
        public let pitch: Double
        public let anchor: Int
        public let bendRange: Int
        public let bend: Int
    }

    /// Same physical extent and string rows as fretted mode. X traverses
    /// the configured semitone span continuously, including both endpoints.
    public func continuousCell(x: Double, y: Double) -> ContinuousCell? {
        guard let cell = cell(x:x,y:y) else { return nil }
        let open = openNotes[cell.string]
        let pitch = Double(open) + x * Double(frets)
        let anchor = open + (frets + 1) / 2
        let range = (frets + 1) / 2
        let delta = (pitch - Double(anchor)) / Double(range)
        let bend = Int((8192 + delta * (delta < 0 ? 8192 : 8191)).rounded())
        return .init(string:cell.string,pitch:pitch,anchor:anchor,bendRange:range,
                     bend:min(16383,max(0,bend)))
    }

    /// Discrete microtonal fret pitch, represented by a nearby MIDI note
    /// plus a bounded per-member bend. No equal-tempered approximation.
    public func microtonalCell(x:Double,y:Double) -> ContinuousCell? {
        guard isMicrotonal, let cell = cell(x:x,y:y),
              let offset = semitoneOffset(at:cell.fret) else { return nil }
        let pitch = Double(openNotes[cell.string])+offset
        let anchor = cell.note
        let delta = (pitch-Double(anchor))/2
        let bend = Int((8192+delta*(delta < 0 ? 8192 : 8191)).rounded())
        return .init(string:cell.string,pitch:pitch,anchor:anchor,bendRange:2,
                     bend:min(16383,max(0,bend)))
    }

    /// Parse a bounded, explicit cents list; no silent sorting or clipping.
    public static func parseFretCents(_ text:String) -> [Int]? {
        guard text.utf8.count <= 2048 else { return nil }
        let tokens = text.split(whereSeparator:{ $0 == "," || $0.isWhitespace })
        guard (2...107).contains(tokens.count) else { return nil }
        let values = tokens.compactMap { Int($0) }
        guard values.count == tokens.count, values.first == 0,
              values.allSatisfy({ (0...2400).contains($0) }),
              zip(values,values.dropFirst()).allSatisfy({ $0.0 < $0.1 }) else { return nil }
        return values
    }

    public func permitsMIDI(mixedFretless:Bool,isMPE:Bool) -> Bool {
        isValid && (!mixedFretless || isMPE)
    }
}
