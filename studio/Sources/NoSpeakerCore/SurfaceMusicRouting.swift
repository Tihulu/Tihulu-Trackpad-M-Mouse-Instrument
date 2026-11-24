import Foundation

/// Each touch surface can independently play pitched notes or General MIDI percussion.
public enum SurfaceInstrumentMode: String, CaseIterable, Identifiable, Sendable, Codable {
    case melodic = "Melodic"
    case drums = "Drums"
    case chords = "Chord Pads"

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

    private static func less(_ lhs: SensorDestination, _ rhs: SensorDestination) -> Bool {
        lhs.channel == rhs.channel ? lhs.number < rhs.number : lhs.channel < rhs.channel
    }
}
