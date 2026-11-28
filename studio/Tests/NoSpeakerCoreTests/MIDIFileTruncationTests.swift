import Foundation
import Testing
@testable import NoSpeakerCore

private func truncationFile(_ tracks: [[UInt8]], extended: Bool = false) -> Data {
    func be(_ value: Int, _ width: Int) -> [UInt8] {
        (0..<width).reversed().map { UInt8((value >> ($0 * 8)) & 255) }
    }
    var bytes = Array("MThd".utf8) + be(extended ? 8 : 6, 4)
    bytes += be(tracks.count == 1 ? 0 : 1, 2) + be(tracks.count, 2) + be(960, 2)
    if extended { bytes += [0x12, 0x34] }
    for track in tracks {
        bytes += Array("MTrk".utf8) + be(track.count, 4) + track
    }
    return Data(bytes)
}

private let truncationNotes: [UInt8] = [0, 0x90, 60, 90, 0x87, 0x40, 60, 0, 0, 0xff, 0x2f, 0]
private let truncationMeta: [UInt8] = [0, 0xff, 0x51, 3, 0x07, 0xa1, 0x20, 0, 0xff, 1, 3, 65, 66, 67, 0, 0xf0, 2, 1, 0xf7, 0x87, 0x40, 0xff, 0x2f, 0]

@Test(arguments: [false, true], [false, true])
func midiRejectsEveryStrictPrefixOfDeclaredFile(extended: Bool, multiple: Bool) throws {
    let file = truncationFile(multiple ? [truncationMeta, truncationNotes] : [truncationNotes], extended: extended)
    let parsed = try MIDIFileParser.parse(file)
    #expect(parsed.notes.count == 1)
    #expect(parsed.durationSeconds == 0.5)
    for count in 0..<file.count {
        #expect(throws: MIDIFileError.truncated) { try MIDIFileParser.parse(Data(file.prefix(count))) }
    }
}

private let incompleteEvents: [[UInt8]] = [
    [0x81], [0], [0, 0x90], [0, 0x90, 60], [0, 0xc0], [0, 0xd0],
    [0, 0xff], [0, 0xff, 1], [0, 0xff, 1, 0x81], [0, 0xff, 1, 2, 65],
    [0, 0xff, 0x51, 3, 7, 0xa1], [0, 0xf0], [0, 0xf0, 0x81], [0, 0xf0, 2, 1],
    [0, 0xf7, 2, 1], [0, 0x90, 60, 90, 0, 60]
]

@Test(arguments: incompleteEvents, [false, true])
func midiIncompleteEventCannotReadPastDeclaredTrack(event: [UInt8], followedByTrack: Bool) {
    let file = truncationFile(followedByTrack ? [event, truncationNotes] : [event])
    #expect(throws: MIDIFileError.truncated) { try MIDIFileParser.parse(file) }
}

@Test(arguments: [[UInt8(0x80), 0x80, 0x80, 0x80, 0], [0, 0xff, 1, 0x80, 0x80, 0x80, 0x80, 0], [0, 0xf0, 0x80, 0x80, 0x80, 0x80, 0], [0, 0xf7, 0x80, 0x80, 0x80, 0x80, 0]])
func midiRejectsOverlongVariableLengthQuantities(event: [UInt8]) {
    #expect(throws: MIDIFileError.malformed("Invalid variable-length quantity")) {
        try MIDIFileParser.parse(truncationFile([event]))
    }
}
