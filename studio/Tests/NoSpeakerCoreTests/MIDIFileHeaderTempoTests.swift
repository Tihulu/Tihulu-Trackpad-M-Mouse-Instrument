import Foundation
import Testing
@testable import NoSpeakerCore

private func headerTempoFile(format: Int = 0, division: Int = 960, tracks: [[UInt8]], extraHeader: [UInt8] = []) -> Data {
    func be(_ value: Int, _ width: Int) -> [UInt8] {
        (0..<width).reversed().map { UInt8((value >> ($0 * 8)) & 255) }
    }
    var bytes = Array("MThd".utf8) + be(6 + extraHeader.count, 4)
    bytes += be(format, 2) + be(tracks.count, 2) + be(division, 2) + extraHeader
    for track in tracks {
        bytes += Array("MTrk".utf8) + be(track.count, 4) + track
    }
    return Data(bytes)
}

private let headerEnd: [UInt8] = [0, 0xff, 0x2f, 0]

@Test(arguments: [0, 1])
func midiRejectsZeroTrackHeader(format: Int) {
    #expect(throws: MIDIFileError.invalidHeader) {
        try MIDIFileParser.parse(headerTempoFile(format: format, tracks: []))
    }
}

@Test(arguments: [2, 3, 16])
func midiFormatZeroRejectsMultipleTracks(count: Int) {
    #expect(throws: MIDIFileError.invalidHeader) {
        try MIDIFileParser.parse(headerTempoFile(tracks: Array(repeating: headerEnd, count: count)))
    }
}

@Test(arguments: [0, 1])
func midiRejectsZeroPPQ(format: Int) {
    #expect(throws: MIDIFileError.unsupportedTiming) {
        try MIDIFileParser.parse(headerTempoFile(format: format, division: 0, tracks: [headerEnd]))
    }
}

@Test(arguments: [0, 1], [false, true])
func midiRejectsZeroTempo(format: Int, delayed: Bool) {
    let event: [UInt8] = [delayed ? 1 : 0, 0xff, 0x51, 3, 0, 0, 0]
    #expect(throws: MIDIFileError.malformed("Tempo must be positive")) {
        try MIDIFileParser.parse(headerTempoFile(format: format, tracks: [event + headerEnd]))
    }
}

@Test(arguments: [1, 96, 960, 32767], [1, 500_000, 16_777_215])
func midiAcceptsPositivePPQAndTempoBounds(ppq: Int, tempo: Int) throws {
    let track: [UInt8] = [0, 0xff, 0x51, 3, UInt8((tempo >> 16) & 255), UInt8((tempo >> 8) & 255), UInt8(tempo & 255), 1, 0xff, 0x2f, 0]
    for format in [0, 1] {
        let parsed = try MIDIFileParser.parse(headerTempoFile(format: format, division: ppq, tracks: [track], extraHeader: [0x12, 0x34]))
        #expect(parsed.notes.isEmpty)
        #expect(abs(parsed.durationSeconds - Double(tempo) / 1_000_000 / Double(ppq)) < 1e-12)
    }
}

@Test func midiRetainsSMPTERejectionAndFormatOneMultiTrack() throws {
    #expect(throws: MIDIFileError.unsupportedTiming) {
        try MIDIFileParser.parse(headerTempoFile(division: 0xe728, tracks: [headerEnd]))
    }
    let parsed = try MIDIFileParser.parse(headerTempoFile(format: 1, tracks: [headerEnd, [0x87, 0x40, 0xff, 0x2f, 0]]))
    #expect(parsed.durationSeconds == 0.5)
}
