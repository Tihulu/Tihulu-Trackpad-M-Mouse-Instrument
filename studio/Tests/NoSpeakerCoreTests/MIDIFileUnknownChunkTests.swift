import Foundation
import Testing
@testable import NoSpeakerCore

private func chunkBE(_ value: Int, _ width: Int) -> [UInt8] {
    (0..<width).reversed().map { UInt8((value >> ($0 * 8)) & 255) }
}

private func midiChunk(_ type: String, _ payload: [UInt8], length: Int? = nil) -> [UInt8] {
    Array(type.utf8) + chunkBE(length ?? payload.count, 4) + payload
}

private func chunkFile(_ chunks: [[UInt8]], tracks: Int) -> Data {
    let header = midiChunk("MThd", [0, tracks == 1 ? 0 : 1] + chunkBE(tracks, 2) + [0x03, 0xc0])
    return Data(header + chunks.flatMap { $0 })
}

private let chunkNotes = midiChunk("MTrk", [0, 0x90, 60, 90, 0x87, 0x40, 60, 0, 0, 0xff, 0x2f, 0])
private let chunkTempo = midiChunk("MTrk", [0, 0xff, 0x51, 3, 0x0f, 0x42, 0x40, 0, 0xff, 0x2f, 0])

@Test(arguments: ["JUNK", "Xtra"], [0, 1, 2])
func midiIgnoresUnknownChunksWithoutInterpretingPayload(type: String, position: Int) throws {
    let payloads: [[UInt8]] = [[], [0xff, 0x80, 0xf0], chunkNotes + chunkTempo]
    for payload in payloads {
        let unknown = midiChunk(type, payload)
        var chunks = [chunkTempo, chunkNotes]
        chunks.insert(unknown, at: position)
        let parsed = try MIDIFileParser.parse(chunkFile(chunks, tracks: 2))
        #expect(parsed.notes == [.init(startSeconds: 0, durationSeconds: 1, channel: 0, note: 60, velocity: 90)])
        #expect(parsed.durationSeconds == 1)
    }
}

@Test func midiUnknownChunksDoNotCountAsDeclaredTracks() throws {
    let unknown = midiChunk("JUNK", [])
    let parsed = try MIDIFileParser.parse(chunkFile([unknown, unknown, chunkNotes], tracks: 1))
    #expect(parsed.notes.count == 1)
    #expect(parsed.durationSeconds == 0.5)
    #expect(throws: MIDIFileError.truncated) {
        try MIDIFileParser.parse(chunkFile([unknown, chunkNotes, unknown], tracks: 2))
    }
}

@Test(arguments: [1, 256, 0xffff_ffff])
func midiRejectsTruncatedUnknownChunk(length: Int) {
    #expect(throws: MIDIFileError.truncated) {
        try MIDIFileParser.parse(chunkFile([midiChunk("JUNK", [], length: length)], tracks: 1))
    }
}

@Test func midiUnknownChunkDoesNotHideMalformedTrackOrDuplicateHeader() {
    let unknown = midiChunk("JUNK", chunkNotes)
    #expect(throws: MIDIFileError.truncated) {
        try MIDIFileParser.parse(chunkFile([unknown, midiChunk("MTrk", [0, 0x90, 60])], tracks: 1))
    }
    #expect(throws: MIDIFileError.malformed("Missing MTrk chunk")) {
        try MIDIFileParser.parse(chunkFile([midiChunk("MThd", [0, 0, 0, 1, 3, 0xc0]), chunkNotes], tracks: 1))
    }
}

@Test func midiUnknownChunksPreserveStrictFilePrefixRejection() throws {
    let file = chunkFile([midiChunk("JUNK", [0xff, 0x80, 0xf0]), chunkTempo,
                          midiChunk("Xtra", []), chunkNotes], tracks: 2)
    #expect(try MIDIFileParser.parse(file).durationSeconds == 1)
    for count in 0..<file.count {
        #expect(throws: MIDIFileError.truncated) {
            try MIDIFileParser.parse(Data(file.prefix(count)))
        }
    }
}
