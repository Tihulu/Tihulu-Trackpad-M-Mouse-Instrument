import Foundation
import Testing
@testable import NoSpeakerCore

private func repeatedNoteFile(_ events: [UInt8]) -> Data {
    let track = events + [0, 0xff, 0x2f, 0]
    let count = track.count
    let length = (0..<4).reversed().map { UInt8((count >> ($0 * 8)) & 255) }
    let header: [UInt8] = [77,84,104,100,0,0,0,6,0,0,0,1,0,100]
    return Data(header + [77,84,114,107] + length + track)
}

@Test(arguments: Array(0...15), [false, true])
func midiRepeatedNoteOnPreservesFIFOOnsets(channel: Int, zeroVelocityOff: Bool) throws {
    let on = UInt8(0x90 | channel), off = UInt8((zeroVelocityOff ? 0x90 : 0x80) | channel)
    let events: [UInt8] = [0,on,60,90, 20,on,60,70, 20,off,60,0, 20,off,60,0]
    let parsed = try MIDIFileParser.parse(repeatedNoteFile(events))
    #expect(parsed.notes.count == 2)
    #expect(parsed.notes.map(\.velocity) == [90,70])
    #expect(parsed.notes.map(\.channel) == [channel,channel])
    #expect(abs((parsed.notes.first?.durationSeconds ?? -1) - 0.2) < 1e-9)
    #expect(abs((parsed.notes.last?.startSeconds ?? -1) - 0.1) < 1e-9)
    #expect(abs((parsed.notes.last?.durationSeconds ?? -1) - 0.2) < 1e-9)
    #expect(abs(parsed.durationSeconds - 0.3) < 1e-9)
}

@Test func midiRepeatedNotesKeepPitchAndChannelQueuesSeparate() throws {
    let events: [UInt8] = [0,0x90,60,80, 10,0x91,60,70, 10,0x90,61,60, 10,0x90,60,50,
                           10,0x81,60,0, 10,0x80,61,0, 10,0x80,60,0, 10,0x80,60,0]
    let notes = try MIDIFileParser.parse(repeatedNoteFile(events)).notes
    #expect(notes.map(\.velocity) == [80,70,60,50])
    #expect(notes.map(\.channel) == [0,1,0,0])
    #expect(notes.map(\.note) == [60,60,61,60])
    for (note, duration) in zip(notes, [0.3,0.15,0.15,0.2]) {
        #expect(abs(note.durationSeconds - duration) < 1e-9)
    }
}

@Test func midiRepeatedNoteQueueDrainsAndRearmsWithoutPhantomNotes() throws {
    let events: [UInt8] = [0,0x80,60,0, 0,0x90,60,80, 10,0x90,60,70, 10,0x80,60,0,
                           10,0x80,60,0, 10,0x80,60,0, 10,0x90,60,60, 10,0x80,60,0,
                           10,0x90,60,50]
    let parsed = try MIDIFileParser.parse(repeatedNoteFile(events))
    #expect(parsed.notes.map(\.velocity) == [80,70,60])
    #expect(abs((parsed.notes.last?.startSeconds ?? -1) - 0.25) < 1e-9)
    #expect(abs(parsed.durationSeconds - 0.35) < 1e-9)
}

@Test func midiRepeatedNoteBurstPreservesAllMatchedOnsets() throws {
    var events: [UInt8] = []
    for index in 0..<4096 { events += [1,0x90,60,UInt8(index % 127 + 1)] }
    for _ in 0..<4096 { events += [1,0x80,60,0] }
    let parsed = try MIDIFileParser.parse(repeatedNoteFile(events))
    #expect(parsed.notes.count == 4096)
    #expect(parsed.notes.map(\.velocity) == (0..<4096).map { $0 % 127 + 1 })
    #expect(parsed.notes.allSatisfy { abs($0.durationSeconds - 20.48) < 1e-8 })
}
