import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public enum MIDIFileError: Error, Equatable {
    case invalidHeader
    case unsupportedTiming
    case truncated
    case resourceLimit
    case malformed(String)
}

public struct MIDIFileNote: Sendable, Equatable {
    public var startSeconds: Double
    public var durationSeconds: Double
    public var channel: Int
    public var note: Int
    public var velocity: Int

    public init(startSeconds: Double, durationSeconds: Double, channel: Int, note: Int, velocity: Int) {
        self.startSeconds = startSeconds
        self.durationSeconds = durationSeconds
        self.channel = channel
        self.note = note
        self.velocity = velocity
    }
}

public struct ParsedMIDIFile: Sendable, Equatable {
    public var notes: [MIDIFileNote]
    public var durationSeconds: Double
}

private struct MIDITrackEvent {
    var tick: Int
    var order: Int
    var kind: Kind

    enum Kind {
        case noteOn(channel: Int, note: Int, velocity: Int)
        case noteOff(channel: Int, note: Int)
        case tempo(microsecondsPerQuarter: Int)
    }
}

public enum MIDIFileParser {
    // Proposed import budgets; not limits of the MIDI standard.
    public static let maximumFileBytes = 16 * 1024 * 1024
    public static let maximumRetainedEvents = 250_000

    /// Read only a regular local file, with a hard byte cap even if it grows
    /// after open. Nonblocking open prevents a named pipe from stalling import.
    public static func parse(contentsOf url: URL) throws -> ParsedMIDIFile {
        guard url.isFileURL else { throw MIDIFileError.malformed("A local MIDI file is required") }
        let fd = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return open(path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        }
        guard fd >= 0 else { throw NSError(domain:NSPOSIXErrorDomain, code:Int(errno)) }
        let handle = FileHandle(fileDescriptor:fd, closeOnDealloc:true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(fd, &info) == 0 else { throw NSError(domain:NSPOSIXErrorDomain, code:Int(errno)) }
        guard (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG) else {
            throw MIDIFileError.malformed("A regular MIDI file is required")
        }
        guard info.st_size >= 0, info.st_size <= maximumFileBytes else { throw MIDIFileError.resourceLimit }
        var data = Data()
        while data.count <= maximumFileBytes {
            let remaining = maximumFileBytes + 1 - data.count
            guard let chunk = try handle.read(upToCount:min(64 * 1024, remaining)), !chunk.isEmpty else { break }
            data.append(chunk)
            guard data.count <= maximumFileBytes else { throw MIDIFileError.resourceLimit }
        }
        return try parse(data)
    }

    public static func parse(_ data: Data) throws -> ParsedMIDIFile {
        guard data.count <= maximumFileBytes else { throw MIDIFileError.resourceLimit }
        let bytes = [UInt8](data)
        var cursor = 0

        func read(_ count: Int) throws -> [UInt8] {
            guard cursor + count <= bytes.count else { throw MIDIFileError.truncated }
            defer { cursor += count }
            return Array(bytes[cursor..<(cursor + count)])
        }
        func u16(_ b: [UInt8]) -> Int { (Int(b[0]) << 8) | Int(b[1]) }
        func u32(_ b: [UInt8]) -> Int { (Int(b[0]) << 24) | (Int(b[1]) << 16) | (Int(b[2]) << 8) | Int(b[3]) }

        guard String(bytes: try read(4), encoding: .ascii) == "MThd" else { throw MIDIFileError.invalidHeader }
        let headerLength = u32(try read(4))
        guard headerLength >= 6 else { throw MIDIFileError.invalidHeader }
        let format = u16(try read(2))
        let trackCount = u16(try read(2))
        let division = u16(try read(2))
        if headerLength > 6 { _ = try read(headerLength - 6) }
        guard format == 0 || format == 1 else { throw MIDIFileError.malformed("Only MIDI formats 0 and 1 are supported") }
        guard division > 0, division & 0x8000 == 0 else { throw MIDIFileError.unsupportedTiming }
        let ticksPerQuarter = division
        guard trackCount > 0, format != 0 || trackCount == 1 else { throw MIDIFileError.invalidHeader }

        var allEvents: [MIDITrackEvent] = []
        var eventOrder = 0
        func record(_ event: MIDITrackEvent) throws {
            guard allEvents.count < maximumRetainedEvents else { throw MIDIFileError.resourceLimit }
            allEvents.append(event)
            eventOrder += 1
        }

        for _ in 0..<trackCount {
            guard String(bytes: try read(4), encoding: .ascii) == "MTrk" else { throw MIDIFileError.malformed("Missing MTrk chunk") }
            let length = u32(try read(4))
            let trackEnd = cursor + length
            guard trackEnd <= bytes.count else { throw MIDIFileError.truncated }
            var tick = 0
            var runningStatus: UInt8?

            func readVariableLength() throws -> Int {
                var value = 0
                for _ in 0..<4 {
                    guard cursor < trackEnd else { throw MIDIFileError.truncated }
                    let byte = bytes[cursor]; cursor += 1
                    value = (value << 7) | Int(byte & 0x7F)
                    if byte & 0x80 == 0 { return value }
                }
                throw MIDIFileError.malformed("Invalid variable-length quantity")
            }

            while cursor < trackEnd {
                tick += try readVariableLength()
                guard cursor < trackEnd else { throw MIDIFileError.truncated }
                var status = bytes[cursor]
                if status < 0x80 {
                    guard let runningStatus else { throw MIDIFileError.malformed("Running status without status byte") }
                    status = runningStatus
                } else {
                    cursor += 1
                    runningStatus = status < 0xF0 ? status : nil
                }

                if status == 0xFF {
                    guard cursor < trackEnd else { throw MIDIFileError.truncated }
                    let type = bytes[cursor]; cursor += 1
                    let metaLength = try readVariableLength()
                    guard cursor + metaLength <= trackEnd else { throw MIDIFileError.truncated }
                    if type == 0x51 {
                        guard metaLength == 3 else { throw MIDIFileError.malformed("Invalid tempo length") }
                        let tempo = (Int(bytes[cursor]) << 16) | (Int(bytes[cursor + 1]) << 8) | Int(bytes[cursor + 2])
                        guard tempo > 0 else { throw MIDIFileError.malformed("Invalid zero tempo") }
                        try record(.init(tick: tick, order: eventOrder, kind: .tempo(microsecondsPerQuarter: tempo)))
                    }
                    cursor += metaLength
                    continue
                }
                if status == 0xF0 || status == 0xF7 {
                    let sysexLength = try readVariableLength()
                    guard cursor + sysexLength <= trackEnd else { throw MIDIFileError.truncated }
                    cursor += sysexLength
                    continue
                }

                guard status < 0xF0 else { throw MIDIFileError.malformed("Unsupported system status") }
                let command = status & 0xF0
                let channel = Int(status & 0x0F)
                let dataLength = (command == 0xC0 || command == 0xD0) ? 1 : 2
                guard cursor + dataLength <= trackEnd else { throw MIDIFileError.truncated }
                let d1 = Int(bytes[cursor]); cursor += 1
                let d2 = dataLength == 2 ? Int(bytes[cursor]) : 0
                if dataLength == 2 { cursor += 1 }
                guard d1 < 128, d2 < 128 else { throw MIDIFileError.malformed("Invalid channel data byte") }

                switch command {
                case 0x80:
                    try record(.init(tick: tick, order: eventOrder, kind: .noteOff(channel: channel, note: d1)))
                case 0x90 where d2 == 0:
                    try record(.init(tick: tick, order: eventOrder, kind: .noteOff(channel: channel, note: d1)))
                case 0x90:
                    try record(.init(tick: tick, order: eventOrder, kind: .noteOn(channel: channel, note: d1, velocity: d2)))
                default:
                    break
                }
            }
            cursor = trackEnd
        }

        allEvents.sort { $0.tick == $1.tick ? $0.order < $1.order : $0.tick < $1.tick }
        var tempo = 500_000
        var lastTick = 0
        var currentSeconds = 0.0
        var active: [String: (start: Double, velocity: Int)] = [:]
        var notes: [MIDIFileNote] = []

        func advance(to tick: Int) {
            let deltaTicks = max(0, tick - lastTick)
            currentSeconds += Double(deltaTicks) * Double(tempo) / 1_000_000.0 / Double(ticksPerQuarter)
            lastTick = tick
        }

        for event in allEvents {
            advance(to: event.tick)
            switch event.kind {
            case .tempo(let value):
                tempo = max(1, value)
            case .noteOn(let channel, let note, let velocity):
                active["\(channel):\(note)"] = (currentSeconds, velocity)
            case .noteOff(let channel, let note):
                let key = "\(channel):\(note)"
                if let start = active.removeValue(forKey: key) {
                    notes.append(MIDIFileNote(
                        startSeconds: start.start,
                        durationSeconds: max(0.01, currentSeconds - start.start),
                        channel: channel,
                        note: note,
                        velocity: start.velocity
                    ))
                }
            }
        }

        notes.sort { $0.startSeconds < $1.startSeconds }
        let duration = notes.map { $0.startSeconds + $0.durationSeconds }.max() ?? currentSeconds
        return ParsedMIDIFile(notes: notes, durationSeconds: duration)
    }

    public static func hapticEvents(from midi: ParsedMIDIFile, safety: HapticSafetyPolicy = .init()) -> [ScheduledHapticEvent] {
        var events: [ScheduledHapticEvent] = []
        for note in midi.notes {
            let level = min(1, max(0, Double(note.velocity) / 127.0))
            if note.channel == 9, let voice = MIDIDrumMap.voice(for: note.note) {
                events.append(.init(time: note.startSeconds, frame: safety.clamp(HapticPatternRenderer.drumFrame(voice, velocity: level))))
            } else if let frequency = try? MusicTheory.frequency(midi: note.note) {
                let durationMS = min(120, max(4, note.durationSeconds * 1_000))
                events.append(.init(
                    time: note.startSeconds,
                    frame: safety.clamp(.init(tones: [.init(frequencyHz: frequency)], durationMS: durationMS, level: level))
                ))
            }
        }
        return events.sorted { $0.time < $1.time }
    }
}
