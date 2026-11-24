import Foundation
import Testing
@testable import NoSpeakerCore

private func midiFixture(_ tracks: [[UInt8]], format: UInt8 = 0, division: UInt16 = 480) -> Data {
    func be32(_ n: Int) -> [UInt8] { [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: n >> $0) } }
    var data = Data([0x4d,0x54,0x68,0x64,0,0,0,6,0,format,UInt8(truncatingIfNeeded:tracks.count >> 8),UInt8(truncatingIfNeeded:tracks.count),UInt8(division >> 8),UInt8(truncatingIfNeeded:division)])
    for track in tracks { data.append(contentsOf: [0x4d,0x54,0x72,0x6b] + be32(track.count) + track) }
    return data
}
private let endOfTrack: [UInt8] = [0,0xff,0x2f,0]
private let simpleTrack: [UInt8] = [0,0x90,60,100,0x83,0x60,0x80,60,0] + endOfTrack

@Test func midiImportRejectsInvalidHeaderAndTiming() {
    for division: UInt16 in [0,0x8000,0xffff] {
        #expect(throws: MIDIFileError.unsupportedTiming) { try MIDIFileParser.parse(midiFixture([simpleTrack],division:division)) }
    }
    #expect(throws: MIDIFileError.invalidHeader) { try MIDIFileParser.parse(midiFixture([])) }
    #expect(throws: MIDIFileError.invalidHeader) { try MIDIFileParser.parse(midiFixture([simpleTrack,simpleTrack])) }
}

@Test func midiImportRejectsInvalidChannelBytesAndSystemStatus() {
    for track: [UInt8] in [[0,0x90,200,100],[0,0x90,60,200],[0,0xf1,1,2]] {
        #expect(throws: MIDIFileError.self) { try MIDIFileParser.parse(midiFixture([track + endOfTrack])) }
    }
}

@Test func midiImportRejectsInvalidTempoAndInterruptedRunningStatus() {
    for track: [UInt8] in [[0,0xff,0x51,3,0,0,0],[0,0xff,0x51,2,1,2],[0,0x90,60,100,0,0xff,1,0,0,60,0],[0,0x90,60,100,0,0xf0,1,0xf7,0,60,0]] {
        #expect(throws: MIDIFileError.self) { try MIDIFileParser.parse(midiFixture([track + endOfTrack])) }
    }
}

@Test func midiImportRetainsValidRunningStatusAndFormatOneTiming() throws {
    let running: [UInt8] = [0,0x90,60,100,0x83,0x60,60,0] + endOfTrack
    let parsed = try MIDIFileParser.parse(midiFixture([running]))
    #expect(parsed.notes.count == 1)
    #expect(abs(parsed.durationSeconds - 0.5) < 0.0001)
    let tempo: [UInt8] = [0,0xff,0x51,3,0x0f,0x42,0x40] + endOfTrack
    let multi = try MIDIFileParser.parse(midiFixture([tempo,simpleTrack],format:1))
    #expect(multi.notes.count == 1)
    #expect(abs(multi.durationSeconds - 1.0) < 0.0001)
}

@Test func midiImportRejectsByteAndEventBudgetOverflow() throws {
    #expect(throws: MIDIFileError.resourceLimit) { try MIDIFileParser.parse(Data(count:MIDIFileParser.maximumFileBytes+1)) }
    let pair: [UInt8] = [0,0x90,60,100,1,0x80,60,0]
    var track = [UInt8](); track.reserveCapacity(MIDIFileParser.maximumRetainedEvents * 4 + 8)
    for _ in 0..<(MIDIFileParser.maximumRetainedEvents/2) { track.append(contentsOf:pair) }
    let valid = try MIDIFileParser.parse(midiFixture([track + endOfTrack]))
    #expect(valid.notes.count == MIDIFileParser.maximumRetainedEvents/2)
    track.append(contentsOf:[0,0x90,60,100])
    #expect(throws: MIDIFileError.resourceLimit) { try MIDIFileParser.parse(midiFixture([track + endOfTrack])) }
}

@Test func midiImportReadsLocalRegularFilesOnly() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString,isDirectory:true)
    try FileManager.default.createDirectory(at:root,withIntermediateDirectories:false)
    defer { try? FileManager.default.removeItem(at:root) }
    let file = root.appendingPathComponent("valid.mid")
    let data = midiFixture([simpleTrack]); try data.write(to:file)
    #expect(try MIDIFileParser.parse(contentsOf:file) == MIDIFileParser.parse(data))
    let link = root.appendingPathComponent("link.mid")
    try FileManager.default.createSymbolicLink(at:link,withDestinationURL:file)
    #expect(try MIDIFileParser.parse(contentsOf:link) == MIDIFileParser.parse(data))
    #expect(throws: MIDIFileError.self) { try MIDIFileParser.parse(contentsOf:root) }
    let remote = try #require(URL(string:"https://example.invalid/song.mid"))
    #expect(throws: MIDIFileError.self) { try MIDIFileParser.parse(contentsOf:remote) }
    let large = root.appendingPathComponent("large.mid")
    try Data(count:MIDIFileParser.maximumFileBytes+1).write(to:large)
    #expect(throws: MIDIFileError.resourceLimit) { try MIDIFileParser.parse(contentsOf:large) }
}
