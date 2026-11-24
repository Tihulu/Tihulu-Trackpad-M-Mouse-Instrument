import Foundation
import Testing
@testable import NoSpeakerCore

private func grooveFixture() throws -> MIDIClip {
    try MIDIClip.melody(.init(bpm: 120, steps: (0..<16).map {
        .init(index: $0, midi: 60, velocity: 0.8, gate: 1)
    }))
}

@Test func grooveIdentityAndSwingPreserveLengthAndNoOverlap() throws {
    let clip = try grooveFixture()
    var groove = GrooveSettings()
    #expect(try groove.apply(to: clip) == clip)
    groove.swing = 75
    let output = try groove.apply(to: clip)
    #expect(output.length == clip.length)
    #expect(output.notes[1].start == 360)
    #expect(output.notes[1].duration == 120)
    #expect(output.notes[2].start == 480)
    #expect(try output.validated() == output)
}

@Test func grooveSeededHumanizeAndProbabilityAreRepeatable() throws {
    let clip = try grooveFixture()
    var groove = GrooveSettings()
    groove.humanize = 100
    groove.probability = 50
    groove.intensity = 75
    groove.accent = 20
    let first = try groove.apply(to: clip)
    #expect(first == (try groove.apply(to: clip)))
    #expect(first.notes.count < clip.notes.count)
    #expect(first.notes.first?.pitch == 60)
    #expect(first.notes.allSatisfy { (1...127).contains($0.velocity) })
    groove.seed = 2
    #expect(first != (try groove.apply(to: clip)))
}

@Test func grooveHapticAndExportShareOnsetsAndVelocity() throws {
    let clip = try MIDIClip.drums(.init(bpm: 120, hits: [
        .init(index: 0, voice: .kick, velocity: 0.8),
        .init(index: 1, voice: .snare, velocity: 0.8)
    ]))
    var groove = GrooveSettings()
    groove.swing = 75
    let output = try groove.apply(to: clip)
    let events = try output.grooveHapticEvents()
    let parsed = try MIDIFileParser.parse(MIDIClipWriter.encode(output))
    #expect(events.count == parsed.notes.count)
    #expect(abs(events[1].time - parsed.notes[1].startSeconds) < 0.000001)
    #expect(abs(events[1].frame.level - Double(parsed.notes[1].velocity) / 127) < 0.000001)
    #expect(events[0].frame.tones.first?.frequencyHz == 120)
}

@Test func grooveRejectsOffGridAndInvalidSettings() throws {
    let clip = try grooveFixture()
    var groove = GrooveSettings()
    groove.swing = 76
    #expect(throws: MIDIClipError.invalidClip) { try groove.apply(to: clip) }
    groove = GrooveSettings()
    var offGrid = clip
    offGrid.notes[0].start = 1
    offGrid.notes[0].duration = 239
    #expect(throws: MIDIClipError.invalidClip) { try groove.apply(to: offGrid) }
    let data = try JSONEncoder().encode(groove)
    #expect(try JSONDecoder().decode(GrooveSettings.self, from: data) == groove)
}
