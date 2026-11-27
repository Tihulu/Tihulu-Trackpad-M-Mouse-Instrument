import Foundation
import Testing
@testable import NoSpeakerCore

private struct GeneratedSMFEvent: Equatable {
    let tick: Int
    let status: UInt8
    let pitch: UInt8
    let velocity: UInt8
}

private struct GeneratedSMFReceipt {
    let tempo: Int
    let endTick: Int
    let events: [GeneratedSMFEvent]
}

// Independent decoder for this writer's explicit-status format-0 output.
private func decodeGeneratedSMF(_ data: Data) throws -> GeneratedSMFReceipt {
    let bytes = Array(data)
    enum InvalidSMF: Error { case malformed }
    var cursor = 0
    func read() throws -> UInt8 {
        guard cursor < bytes.count else { throw InvalidSMF.malformed }
        defer { cursor += 1 }
        return bytes[cursor]
    }
    func be(_ count: Int) throws -> Int {
        var value = 0
        for _ in 0..<count { value = (value << 8) | Int(try read()) }
        return value
    }
    func vlq() throws -> Int {
        var value = 0
        for _ in 0..<4 {
            let byte = try read()
            value = (value << 7) | Int(byte & 127)
            if byte & 128 == 0 { return value }
        }
        throw InvalidSMF.malformed
    }
    guard try be(4) == 0x4d546864, try be(4) == 6,
          try be(2) == 0, try be(2) == 1, try be(2) == 960,
          try be(4) == 0x4d54726b, try be(4) == bytes.count - cursor
    else { throw InvalidSMF.malformed }
    var tick = 0
    var tempo: Int?
    var events: [GeneratedSMFEvent] = []
    while cursor < bytes.count {
        tick += try vlq()
        let status = try read()
        switch status {
        case 0xff:
            let type = try read()
            let length = try vlq()
            if type == 0x51, length == 3, tick == 0, tempo == nil, events.isEmpty {
                tempo = try be(3)
            } else if type == 0x2f, length == 0, cursor == bytes.count, let tempo {
                return .init(tempo: tempo, endTick: tick, events: events)
            } else { throw InvalidSMF.malformed }
        case 0x80...0x9f:
            let pitch = try read(), velocity = try read()
            guard tempo != nil, pitch < 128, velocity < 128 else { throw InvalidSMF.malformed }
            events.append(.init(tick: tick, status: status, pitch: pitch, velocity: velocity))
        default: throw InvalidSMF.malformed
        }
    }
    throw InvalidSMF.malformed
}

@Test(arguments: Array(0..<16), MelodicPatternGenerator.Role.allCases)
func generatedMelodyFullGateRetriggersAreBalanced(channel: Int, role: MelodicPatternGenerator.Role) throws {
    for bpm in [20.0, 300.0] {
        for pitch in [0, 127] {
            var c = MelodicPatternGenerator.Configuration()
            c.role = role; c.root = pitch % 12; c.low = pitch; c.high = pitch
            c.bpm = bpm; c.bars = 16; c.density = 100; c.gate = 1; c.velocity = 1
            c.seed = UInt64.max
            let sequence = try MelodicPatternGenerator.generate(c)
            let bytes = try MIDIClipWriter.encode(MIDIClip.melody(sequence, channel: channel))
            let receipt = try decodeGeneratedSMF(bytes)
            #expect(receipt.tempo == Int((60_000_000 / bpm).rounded()))
            #expect(receipt.endTick == 61_440)
            var expected: [GeneratedSMFEvent] = []
            for index in 0..<256 {
                expected.append(.init(tick: index * 240, status: UInt8(0x90 | channel), pitch: UInt8(pitch),
                                      velocity: index % 4 == 0 ? 127 : 104))
                expected.append(.init(tick: (index + 1) * 240, status: UInt8(0x80 | channel), pitch: UInt8(pitch), velocity: 0))
            }
            #expect(receipt.events == expected)
            #expect(bytes == (try MIDIClipWriter.encode(MIDIClip.melody(MelodicPatternGenerator.generate(c), channel: channel))))
        }
    }
}

@Test(arguments: MelodicPatternGenerator.Genre.allCases, MelodicPatternGenerator.Role.allCases)
func generatedMelodySparseExportPreservesTrailingRest(genre: MelodicPatternGenerator.Genre, role: MelodicPatternGenerator.Role) throws {
    var c = MelodicPatternGenerator.Configuration()
    c.genre = genre; c.role = role; c.bars = 2; c.density = 0; c.gate = 0.05; c.velocity = 0.01
    c.variation = 0; c.complexity = 0; c.seed = 0
    let sequence = try MelodicPatternGenerator.generate(c)
    let bytes = try MIDIClipWriter.encode(MIDIClip.melody(sequence, channel: 15))
    let receipt = try decodeGeneratedSMF(bytes)
    #expect(receipt.endTick == 7680)
    #expect(receipt.tempo == 500_000)
    #expect(receipt.events.count == 4)
    var expected: [GeneratedSMFEvent] = []
    for step in sequence.steps {
        let pitch = try #require(step.midi)
        expected.append(.init(tick: step.index * 240, status: 0x9f, pitch: UInt8(pitch), velocity: 1))
        expected.append(.init(tick: step.index * 240 + 12, status: 0x8f, pitch: UInt8(pitch), velocity: 0))
    }
    #expect(receipt.events == expected)
    let last = try #require(receipt.events.last)
    #expect(last.tick < receipt.endTick)
}
