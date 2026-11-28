import Foundation
import Testing
@testable import NoSpeakerCore

private func silenceMIDIFile(tracks: [[UInt8]]) -> Data {
    func bigEndian(_ n: Int, width: Int) -> [UInt8] {
        (0..<width).reversed().map { UInt8((n >> ($0 * 8)) & 255) }
    }
    var bytes = Array("MThd".utf8) + [0, 0, 0, 6, 0, tracks.count == 1 ? 0 : 1]
    bytes += bigEndian(tracks.count, width: 2) + [0x03, 0xc0] // 960 PPQ
    for track in tracks {
        bytes += Array("MTrk".utf8) + bigEndian(track.count, width: 4) + track
    }
    return Data(bytes)
}

private func silenceVLQ(_ value: Int) -> [UInt8] {
    var n = value
    var bytes = [UInt8(n & 127)]
    n >>= 7
    while n > 0 { bytes.append(UInt8(n & 127) | 128); n >>= 7 }
    return Array(bytes.reversed())
}

@Test(arguments: [0, 1, 127, 128, 960, 3840, 16384])
func midiParserPreservesTrailingRestAfterNoteOff(rest: Int) throws {
    let track: [UInt8] = [0, 0x90, 60, 90] + silenceVLQ(960) + [0x80, 60, 0]
        + silenceVLQ(rest) + [0xff, 0x2f, 0]
    let parsed = try MIDIFileParser.parse(silenceMIDIFile(tracks: [track]))
    #expect(parsed.notes == [.init(startSeconds: 0, durationSeconds: 0.5, channel: 0, note: 60, velocity: 90)])
    #expect(abs(parsed.durationSeconds - Double(960 + rest) / 1920) < 0.000001)
}

@Test func midiParserUsesLongestTrackAndTempoMapThroughSilence() throws {
    let notes: [UInt8] = [0, 0x90, 60, 90] + silenceVLQ(960) + [0x80, 60, 0, 0, 0xff, 0x2f, 0]
    // At tick 1920, tempo changes to 1 second per quarter; end at tick 3840.
    let tempo: [UInt8] = silenceVLQ(1920) + [0xff, 0x51, 3, 0x0f, 0x42, 0x40]
        + silenceVLQ(1920) + [0xff, 0x2f, 0]
    let silent: [UInt8] = silenceVLQ(4800) + [0xff, 0x2f, 0]
    for tracks in [[notes, tempo, silent], [tempo, silent, notes], [silent, notes, tempo]] {
        let parsed = try MIDIFileParser.parse(silenceMIDIFile(tracks: tracks))
        #expect(parsed.notes.count == 1)
        #expect(parsed.notes.first?.durationSeconds == 0.5)
        #expect(parsed.durationSeconds == 4)
    }
}

@Test(arguments: [0, 1, 960, 3840])
func midiParserReportsDurationOfSilentTrack(ticks: Int) throws {
    let parsed = try MIDIFileParser.parse(silenceMIDIFile(tracks: [silenceVLQ(ticks) + [0xff, 0x2f, 0]]))
    #expect(parsed.notes.isEmpty)
    #expect(abs(parsed.durationSeconds - Double(ticks) / 1920) < 0.000001)
}

@Test func midiParserRetainsMinimumNoteDurationPastTrackEnd() throws {
    let track: [UInt8] = [0, 0x90, 60, 90, 0, 0x80, 60, 0, 0, 0xff, 0x2f, 0]
    let parsed = try MIDIFileParser.parse(silenceMIDIFile(tracks: [track]))
    #expect(parsed.notes.first?.durationSeconds == 0.01)
    #expect(parsed.durationSeconds == 0.01)
}
