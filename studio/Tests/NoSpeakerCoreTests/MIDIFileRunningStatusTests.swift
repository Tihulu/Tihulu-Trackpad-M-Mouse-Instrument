import Foundation
import Testing
@testable import NoSpeakerCore

private func runningStatusFile(_ tracks: [[UInt8]]) -> Data {
    let header: [UInt8] = [0x4d, 0x54, 0x68, 0x64, 0, 0, 0, 6, 0, tracks.count == 1 ? 0 : 1, 0, UInt8(tracks.count), 3, 0xc0]
    var bytes = header
    for track in tracks {
        let length = (0..<4).reversed().map { UInt8((track.count >> ($0 * 8)) & 255) }
        bytes += [0x4d, 0x54, 0x72, 0x6b] + length + track
    }
    return Data(bytes)
}

private let runningBarriers: [[UInt8]] = [
    [0, 0xff, 1, 1, 0x41],
    [0, 0xff, 0x51, 3, 0x07, 0xa1, 0x20],
    [0, 0xf0, 1, 0xf7],
    [0, 0xf7, 1, 0xff]
]

@Test(arguments: Array(UInt8(0)...15), runningBarriers)
func midiRunningStatusCannotCrossMetaOrSysEx(channel: UInt8, barrier: [UInt8]) {
    let track: [UInt8] = [0, 0x90 | channel, 60, 90] + barrier
        + [0x87, 0x40, 60, 0, 0, 0xff, 0x2f, 0]
    #expect(throws: MIDIFileError.malformed("Running status without status byte")) {
        try MIDIFileParser.parse(runningStatusFile([track]))
    }
}

@Test(arguments: Array(UInt8(0)...15), runningBarriers)
func midiExplicitStatusRestartsAfterMetaOrSysEx(channel: UInt8, barrier: [UInt8]) throws {
    let track: [UInt8] = [0, 0x90 | channel, 60, 90] + barrier
        + [0, 0x90 | channel, 61, 80, 0x87, 0x40, 60, 0, 0, 61, 0, 0, 0xff, 0x2f, 0]
    let parsed = try MIDIFileParser.parse(runningStatusFile([track]))
    #expect(Set(parsed.notes.map(\.note)) == [60, 61])
    #expect(parsed.notes.allSatisfy { $0.channel == Int(channel) && $0.durationSeconds == 0.5 })
    #expect(parsed.durationSeconds == 0.5)
}

@Test func midiRunningStatusIsLocalToTrack() {
    let first: [UInt8] = [0, 0x90, 60, 90, 0, 0xff, 0x2f, 0]
    let second: [UInt8] = [0, 61, 90, 0, 0xff, 0x2f, 0]
    #expect(throws: MIDIFileError.malformed("Running status without status byte")) {
        try MIDIFileParser.parse(runningStatusFile([first, second]))
    }
}
