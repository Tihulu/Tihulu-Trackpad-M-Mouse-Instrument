import Foundation
import Testing
@testable import NoSpeakerCore

@Test func midiClipMelodyRoundTripPreservesTimingAndVelocity() throws {
    let sequence = NoteSequence(bpm: 120, steps: [
        .init(index: 0, midi: 60, velocity: 1, gate: 1),
        .init(index: 1, midi: 60, velocity: 0.5, gate: 0.8)
    ])
    let clip = try MIDIClip.melody(sequence)
    #expect(clip.length == 3840)
    let data = try MIDIClipWriter.encode(clip)
    #expect(data.prefix(4) == Data("MThd".utf8))
    let parsed = try MIDIFileParser.parse(data)
    #expect(parsed.notes.count == 2)
    #expect(parsed.notes.map(\.velocity) == [127,64])
    #expect(abs(parsed.notes[1].startSeconds - 0.125) < 0.000001)
    #expect(abs(parsed.notes[1].durationSeconds - 0.1) < 0.000001)
    // 3840 - (240+192) = 3408 ticks, VLQ 0x9A 0x50.
    #expect(data.suffix(5) == Data([0x9A,0x50,0xFF,0x2F,0]))
}

@Test func midiClipDrumsUseGMChannelAndPitch() throws {
    let clip = try MIDIClip.drums(.init(bpm: 100, hits: [
        .init(index: 0, voice: .kick), .init(index: 0, voice: .closedHat),
        .init(index: 4, voice: .snare), .init(index: 14, voice: .tom)
    ]))
    let parsed = try MIDIFileParser.parse(MIDIClipWriter.encode(clip))
    #expect(Set(parsed.notes.map(\.note)) == Set([36,42,38,47]))
    #expect(parsed.notes.allSatisfy { $0.channel == 9 })
    #expect(parsed.notes.count == 4)
}

@Test func midiClipProgressionExportsArpeggioAndTrailingRest() throws {
    var progression = ChordProgression()
    progression.slots = [0,nil]
    progression.beatsPerStep = 1
    progression.gatePercent = 100
    var arp = ArpeggioSettings()
    arp.notesPerBeat = 3
    progression.arpeggio = arp
    let clip = try MIDIClip.progression(progression, bank: ChordBank(), bpm: 120)
    #expect(clip.length == 1920)
    #expect(clip.notes.map(\.start) == [0,320,640])
    #expect(clip.notes.map(\.pitch) == [60,64,67])
    #expect(clip.notes.allSatisfy { $0.duration == 320 })
    let parsed = try MIDIFileParser.parse(MIDIClipWriter.encode(clip))
    #expect(parsed.notes.count == 3)
}

@Test func midiClipRejectsOverlapsInvalidNumbersAndEmptyData() {
    let n = MIDIClip.Note(start: 0, duration: 240, channel: 0, pitch: 60, velocity: 90)
    #expect(throws: MIDIClipError.overlappingNote) {
        try MIDIClipWriter.encode(.init(bpm: 120, length: 960, notes: [n,n]))
    }
    #expect(throws: MIDIClipError.invalidClip) {
        try MIDIClipWriter.encode(.init(bpm: .nan, length: 960, notes: [n]))
    }
    var invalid = n
    invalid.duration = Int.max
    #expect(throws: MIDIClipError.invalidNote) {
        try MIDIClipWriter.encode(.init(bpm: 120, length: 960, notes: [invalid]))
    }
    #expect(throws: MIDIClipError.empty) {
        try MIDIClipWriter.encode(.init(bpm: 120, length: 960, notes: []))
    }
}
