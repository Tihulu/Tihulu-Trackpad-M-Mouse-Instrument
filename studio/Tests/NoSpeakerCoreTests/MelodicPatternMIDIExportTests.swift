import Foundation
import Testing
@testable import NoSpeakerCore

private struct GeneratedSMFReader {
    let bytes: [UInt8]
    var position = 0
    enum Invalid: Error { case malformed }

    mutating func read(_ count: Int) throws -> [UInt8] {
        guard count >= 0, count <= bytes.count - position else { throw Invalid.malformed }
        defer { position += count }
        return Array(bytes[position..<(position + count)])
    }
    mutating func integer(_ count: Int) throws -> Int {
        try read(count).reduce(0) { ($0 << 8) | Int($1) }
    }
    mutating func delta() throws -> Int {
        var value = 0
        for _ in 0..<4 {
            let byte = try integer(1)
            value = (value << 7) | (byte & 127)
            if byte < 128 { return value }
        }
        throw Invalid.malformed
    }
}

@Test(arguments: MelodicPatternGenerator.Genre.allCases, MelodicPatternGenerator.Role.allCases)
func generatedMelodiesExportCompleteMIDITracks(genre: MelodicPatternGenerator.Genre, role: MelodicPatternGenerator.Role) throws {
    for (bars, density, gate, bpm, seed, velocity): (Int, Int, Double, Double, UInt64, Double) in [
        (1, 0, 0.05, 20, 0, 0.01), (2, 40, 0.65, 123.5, 42, 0.85), (16, 100, 1, 300, UInt64.max, 1)
    ] {
        var config = MelodicPatternGenerator.Configuration()
        config.genre = genre; config.role = role; config.bars = bars
        config.density = density; config.gate = gate; config.bpm = bpm
        config.seed = seed; config.velocity = velocity
        config.low = role == .bass ? 28 : 60; config.high = role == .bass ? 59 : 96
        config.complexity = 100; config.variation = 100
        let pattern = try MelodicPatternGenerator.generate(config)
        let regenerated = try MelodicPatternGenerator.generate(config)
        for channel in [0, 9, 15] {
            let data = try MIDIClipWriter.encode(MIDIClip.melody(pattern, channel: channel))
            #expect(data == (try MIDIClipWriter.encode(MIDIClip.melody(regenerated, channel: channel))))
            var reader = GeneratedSMFReader(bytes: Array(data))
            #expect(try reader.read(4) == Array("MThd".utf8))
            #expect(try reader.integer(4) == 6)
            #expect(try reader.integer(2) == 0)
            #expect(try reader.integer(2) == 1)
            #expect(try reader.integer(2) == 960)
            #expect(try reader.read(4) == Array("MTrk".utf8))
            let trackLength = try reader.integer(4)
            #expect(trackLength == data.count - reader.position)
            #expect(try reader.read(4) == [0, 255, 81, 3])
            #expect(try reader.integer(3) == Int((60_000_000 / bpm).rounded()))
            var tick = 0
            for step in pattern.steps.sorted(by: { $0.index < $1.index }) {
                let pitch = try #require(step.midi)
                tick += try reader.delta()
                #expect(tick == step.index * 240)
                #expect(try reader.integer(1) == (0x90 | channel))
                #expect(try reader.integer(1) == pitch)
                #expect(try reader.integer(1) == max(1, Int((step.velocity * 127).rounded())))
                tick += try reader.delta()
                #expect(tick == step.index * 240 + Int((gate * 240).rounded()))
                #expect(try reader.integer(1) == (0x80 | channel))
                #expect(try reader.integer(1) == pitch)
                #expect(try reader.integer(1) == 0)
            }
            tick += try reader.delta()
            #expect(tick == bars * 16 * 240)
            #expect(try reader.read(3) == [255, 47, 0])
            #expect(reader.position == data.count)
        }
    }
}
