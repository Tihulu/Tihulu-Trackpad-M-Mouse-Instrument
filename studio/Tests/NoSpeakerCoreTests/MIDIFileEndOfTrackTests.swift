import Foundation
import Testing
@testable import NoSpeakerCore

private func eotFile(_ tracks: [[UInt8]]) -> Data {
    var bytes: [UInt8] = [0x4d, 0x54, 0x68, 0x64, 0, 0, 0, 6, 0, tracks.count == 1 ? 0 : 1, 0, UInt8(tracks.count), 3, 0xc0]
    for track in tracks {
        let length = (0..<4).reversed().map { UInt8((track.count >> ($0 * 8)) & 255) }
        bytes += [0x4d, 0x54, 0x72, 0x6b] + length + track
    }
    return Data(bytes)
}

@Test(arguments: [1, 2, 3, 127])
func midiRejectsNonzeroEndOfTrackPayload(length: Int) {
    let track: [UInt8] = [0, 0xff, 0x2f, UInt8(length)] + Array(repeating: 0, count: length)
    #expect(throws: MIDIFileError.malformed("End of Track must have zero length")) {
        try MIDIFileParser.parse(eotFile([track]))
    }
}

@Test(arguments: [[UInt8(0), 0xff, 0x2f, 0], [0, 0x90, 60, 90], [0, 0xff, 1, 0], [0, 0xf0, 1, 0xf7], [0]])
func midiRejectsBytesAfterEndOfTrack(suffix: [UInt8]) {
    let track: [UInt8] = [0, 0xff, 0x2f, 0] + suffix
    #expect(throws: MIDIFileError.malformed("Events after End of Track")) {
        try MIDIFileParser.parse(eotFile([track]))
    }
}

@Test func midiEndOfTrackDoesNotConsumeFollowingTrack() throws {
    let silence: [UInt8] = [0x8f, 0, 0xff, 0x2f, 0]
    let notes: [UInt8] = [0, 0x90, 60, 90, 0x87, 0x40, 0x80, 60, 0, 0, 0xff, 0x2f, 0]
    for tracks in [[silence, notes], [notes, silence]] {
        let parsed = try MIDIFileParser.parse(eotFile(tracks))
        #expect(parsed.notes.count == 1)
        #expect(parsed.notes.first?.durationSeconds == 0.5)
        #expect(parsed.durationSeconds == 1)
    }
}

@Test func midiMissingEndOfTrackRemainsTolerated() throws {
    let notes: [UInt8] = [0, 0x90, 60, 90, 0x87, 0x40, 0x80, 60, 0]
    let parsed = try MIDIFileParser.parse(eotFile([notes]))
    #expect(parsed.notes.count == 1)
    #expect(parsed.durationSeconds == 0.5)
}
