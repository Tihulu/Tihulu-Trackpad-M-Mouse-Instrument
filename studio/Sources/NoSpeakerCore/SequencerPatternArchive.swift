import Foundation

/// Versioned, offline editor data. Import never opens a device, starts
/// playback, changes the active take or restores a transient UI identity.
public struct SequencerPatternArchive: Equatable, Sendable {
    public enum ArchiveError: Error, Equatable {
        case invalidSize, invalidSchema, unsupportedVersion, duplicateKey
    }

    private enum Kind: String, Codable, Sendable { case notes, drums }
    private struct NoteCell: Codable, Equatable, Sendable {
        let index: Int
        let midi: Int?
        let velocity: Double
        let gate: Double
        var step: NoteStep { .init(index: index, midi: midi, velocity: velocity, gate: gate) }
    }
    private struct DrumCell: Codable, Equatable, Sendable {
        let index: Int
        let voice: DrumVoice
        let velocity: Double
        var hit: DrumStep { .init(index: index, voice: voice, velocity: velocity) }
    }
    private struct Payload: Codable, Equatable, Sendable {
        let version: Int
        let kind: Kind
        let bpm: Double
        let stepsPerBeat: Int
        let length: Int
        let loop: Bool
        let groove: GrooveSettings?
        let channel: Int?
        let notes: [NoteCell]?
        let hits: [DrumCell]?
    }

    public static let maximumBytes = 1_048_576
    private let payload: Payload
    public var kind: FrozenSequencerPattern.Kind { payload.kind == .notes ? .notes : .drums }
    public var loop: Bool { payload.loop }
    public var groove: GrooveSettings? { payload.groove }
    public var channel: Int? { payload.channel }

    public init(notes: NoteSequence, channel: Int = 0, loop: Bool = false,
                groove: GrooveSettings? = nil) throws {
        try FrozenSequencerPattern.validate(notes: notes, channel: channel, groove: groove)
        payload = .init(version: 1, kind: .notes, bpm: notes.bpm,
                        stepsPerBeat: notes.stepsPerBeat, length: notes.length,
                        loop: loop, groove: groove, channel: channel,
                        notes: notes.steps.sorted { $0.index < $1.index }.map {
                            .init(index: $0.index, midi: $0.midi, velocity: $0.velocity == 0 ? 0 : $0.velocity, gate: $0.gate)
                        }, hits: nil)
    }

    public init(drums: DrumSequence, loop: Bool = false, groove: GrooveSettings? = nil) throws {
        try FrozenSequencerPattern.validate(drums: drums, groove: groove)
        payload = .init(version: 1, kind: .drums, bpm: drums.bpm,
                        stepsPerBeat: drums.stepsPerBeat, length: drums.length,
                        loop: loop, groove: groove, channel: nil, notes: nil,
                        hits: drums.hits.sorted {
                            $0.index == $1.index ? $0.voice.rawValue < $1.voice.rawValue : $0.index < $1.index
                        }.map { .init(index: $0.index, voice: $0.voice, velocity: $0.velocity == 0 ? 0 : $0.velocity) })
    }

    /// Each call creates new transient step IDs. Musical cells are preserved.
    public func noteDraft() -> NoteSequence? {
        guard let cells = payload.notes else { return nil }
        return .init(bpm: payload.bpm, stepsPerBeat: payload.stepsPerBeat,
                     length: payload.length, steps: cells.map(\.step))
    }

    public func drumDraft() -> DrumSequence? {
        guard let cells = payload.hits else { return nil }
        return .init(bpm: payload.bpm, stepsPerBeat: payload.stepsPerBeat,
                     length: payload.length, hits: cells.map(\.hit))
    }

    /// An explicit caller action; an empty or groove-filtered silent draft
    /// is still rejected by the existing playback planner.
    public func frozen() throws -> FrozenSequencerPattern {
        if let draft = noteDraft(), let channel {
            return try .init(notes: draft, channel: channel, loop: loop, groove: groove)
        }
        if let draft = drumDraft() { return try .init(drums: draft, loop: loop, groove: groove) }
        throw ArchiveError.invalidSchema
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(payload)
        guard data.count <= Self.maximumBytes else { throw ArchiveError.invalidSize }
        return data
    }

    public static func decode(_ data: Data) throws -> Self {
        guard !data.isEmpty, data.count <= maximumBytes else { throw ArchiveError.invalidSize }
        try validateStructure(data)
        // Reject unknown fields rather than silently dropping unsupported
        // musical settings. This remains an offline editor format.
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ArchiveError.invalidSchema
        }
        let common: Set<String> = ["version", "kind", "bpm", "stepsPerBeat", "length", "loop"]
        guard let kind = object["kind"] as? String else { throw ArchiveError.invalidSchema }
        switch kind {
        case "notes":
            guard keys(object, required: common.union(["channel", "notes"]), optional: ["groove"]),
                  let cells = object["notes"] as? [[String: Any]], cells.count <= 4096,
                  cells.allSatisfy({ keys($0, required: ["index", "velocity", "gate"], optional: ["midi"]) })
            else { throw ArchiveError.invalidSchema }
        case "drums":
            guard keys(object, required: common.union(["hits"]), optional: ["groove"]),
                  let cells = object["hits"] as? [[String: Any]], cells.count <= 16_384,
                  cells.allSatisfy({ keys($0, required: ["index", "voice", "velocity"]) })
            else { throw ArchiveError.invalidSchema }
        default: throw ArchiveError.invalidSchema
        }
        if let rawGroove = object["groove"] {
            guard let groove = rawGroove as? [String: Any],
                  keys(groove, required: ["swing", "humanize", "intensity", "accent", "probability", "seed"])
            else { throw ArchiveError.invalidSchema }
        }
        let decoded = try JSONDecoder().decode(Payload.self, from: data)
        guard decoded.version == 1 else { throw ArchiveError.unsupportedVersion }
        switch decoded.kind {
        case .notes:
            guard let cells = decoded.notes, let channel = decoded.channel else { throw ArchiveError.invalidSchema }
            return try .init(notes: .init(bpm: decoded.bpm, stepsPerBeat: decoded.stepsPerBeat,
                                          length: decoded.length, steps: cells.map(\.step)),
                             channel: channel, loop: decoded.loop, groove: decoded.groove)
        case .drums:
            guard let cells = decoded.hits else { throw ArchiveError.invalidSchema }
            return try .init(drums: .init(bpm: decoded.bpm, stepsPerBeat: decoded.stepsPerBeat,
                                          length: decoded.length, hits: cells.map(\.hit)),
                             loop: decoded.loop, groove: decoded.groove)
        }
    }

    // JSONSerialization and JSONDecoder may resolve duplicate keys differently.
    // Scan only structure and decoded object keys; Foundation remains the
    // authority for full JSON grammar and value types. V1 needs at most three
    // containers (root, cells array, cell object). Bound before parsing.
    private enum Scope {
        case object(Set<String>)
        case array
    }

    private static func validateStructure(_ data: Data) throws {
        let bytes = Array(data)
        guard !bytes.contains(0), String(data: data, encoding: .utf8) != nil else {
            throw ArchiveError.invalidSchema
        }
        func whitespace(_ b: UInt8) -> Bool { b == 32 || b == 9 || b == 10 || b == 13 }
        var scopes: [Scope] = []
        var i = 0
        while i < bytes.count {
            switch bytes[i] {
            case 123, 91: // { or [
                guard scopes.count < 3 else { throw ArchiveError.invalidSchema }
                scopes.append(bytes[i] == 123 ? .object([]) : .array)
                i += 1
            case 125: // }
                guard case .object? = scopes.popLast() else { throw ArchiveError.invalidSchema }
                i += 1
            case 93: // ]
                guard case .array? = scopes.popLast() else { throw ArchiveError.invalidSchema }
                i += 1
            case 34: // quoted string; escaped quotes and braces are not structure
                let start = i
                var escaped = false
                i += 1
                while i < bytes.count, bytes[i] != 34 {
                    if bytes[i] == 92 { escaped = true; i += 1 }
                    i += 1
                }
                guard i < bytes.count else { throw ArchiveError.invalidSchema }
                i += 1
                let end = i
                while i < bytes.count, whitespace(bytes[i]) { i += 1 }
                if i < bytes.count, bytes[i] == 58 { // object key
                    guard case .object(var keys)? = scopes.last else { throw ArchiveError.invalidSchema }
                    let key = escaped
                        ? try JSONDecoder().decode(String.self, from: Data(bytes[start..<end]))
                        : String(decoding: bytes[(start + 1)..<(end - 1)], as: UTF8.self)
                    guard !keys.contains(key) else { throw ArchiveError.duplicateKey }
                    guard keys.count < 9 else { throw ArchiveError.invalidSchema }
                    keys.insert(key)
                    scopes[scopes.count - 1] = .object(keys)
                }
            default: i += 1
            }
        }
        guard scopes.isEmpty else { throw ArchiveError.invalidSchema }
    }

    private static func keys(_ object: [String: Any], required: Set<String>,
                             optional: Set<String> = []) -> Bool {
        let actual = Set(object.keys)
        return required.isSubset(of: actual) && actual.isSubset(of: required.union(optional))
    }
}
