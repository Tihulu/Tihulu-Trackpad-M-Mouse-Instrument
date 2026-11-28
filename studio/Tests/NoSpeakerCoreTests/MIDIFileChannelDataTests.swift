import Foundation
import Testing
@testable import NoSpeakerCore

private func channelDataMIDI(_ track: [UInt8]) -> Data {
    let size = (0..<4).reversed().map { UInt8((track.count >> ($0 * 8)) & 255) }
    let header: [UInt8] = [0x4d, 0x54, 0x68, 0x64, 0, 0, 0, 6, 0, 0, 0, 1, 3, 0xc0]
    return Data(header + [0x4d, 0x54, 0x72, 0x6b] + size + track)
}

@Test(arguments: [UInt8(0x80), 0x89, 0x8f, 0x90, 0x99, 0x9f, 0xa0, 0xa9, 0xaf,
                  0xb0, 0xb9, 0xbf, 0xc0, 0xc9, 0xcf, 0xd0, 0xd9, 0xdf, 0xe0, 0xe9, 0xef],
      [UInt8(0x80), 0xff])
func midiRejectsHighBitChannelData(status: UInt8, invalid: UInt8) {
    let command = status & 0xf0
    let length = command == 0xc0 || command == 0xd0 ? 1 : 2
    for position in 0..<length {
        var data = Array(repeating: UInt8(60), count: length)
        data[position] = invalid
        let track: [UInt8] = [0, status] + data + [0, 0xff, 0x2f, 0]
        #expect(throws: MIDIFileError.malformed("Invalid MIDI channel data byte")) {
            try MIDIFileParser.parse(channelDataMIDI(track))
        }
    }
}

@Test(arguments: Array(UInt8(0xf1)...0xf6) + Array(UInt8(0xf8)...0xfe))
func midiRejectsUnsupportedSystemStatus(status: UInt8) {
    #expect(throws: MIDIFileError.malformed("Unsupported MIDI status byte")) {
        try MIDIFileParser.parse(channelDataMIDI([0, status, 0, 0, 0, 0xff, 0x2f, 0]))
    }
}

@Test(arguments: Array(UInt8(0)...15))
func midiPreservesValidExplicitAndRunningChannelEvents(channel: UInt8) throws {
    let track: [UInt8] = [0, 0xc0 | channel, 127, 0, 0xd0 | channel, 0,
        0, 0xb0 | channel, 64, 127, 0, 0xe0 | channel, 127, 127,
        0, 0x90 | channel, 0, 127, 0, 127, 1,
        0x87, 0x40, 0, 0, 0, 127, 0,
        0, 0xff, 1, 1, 0xff, 0, 0xf0, 1, 0xf7,
        0, 0xf7, 1, 0xff, 0, 0xff, 0x2f, 0]
    let parsed = try MIDIFileParser.parse(channelDataMIDI(track))
    #expect(parsed.notes.count == 2)
    #expect(Set(parsed.notes.map(\.note)) == [0, 127])
    #expect(Set(parsed.notes.map(\.velocity)) == [1, 127])
    #expect(parsed.notes.allSatisfy { $0.channel == Int(channel) && $0.durationSeconds == 0.5 })
    #expect(parsed.durationSeconds == 0.5)
}
