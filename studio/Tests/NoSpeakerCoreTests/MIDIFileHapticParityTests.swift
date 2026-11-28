import Foundation
import Testing
@testable import NoSpeakerCore

private func parityNote(channel: Int = 9, pitch: Int = 36, velocity: Int = 100,
                        start: Double = 0.25, duration: Double = 0.5) -> MIDIFileNote {
    .init(startSeconds: start, durationSeconds: duration, channel: channel, note: pitch, velocity: velocity)
}

@Test(arguments: Array(0...127), [1, 64, 127])
func midiFileDrumsMatchSharedHapticProfiles(pitch: Int, velocity: Int) {
    let midi = ParsedMIDIFile(notes: [parityNote(pitch: pitch, velocity: velocity)], durationSeconds: 1)
    let safety = HapticSafetyPolicy(maxLevel: 0.6, maxTonesPerFrame: 1, maxFrameDurationMS: 55)
    let expected = HapticPatternRenderer.drumFrame(midiNote: pitch, velocity: Double(velocity) / 127)
        .map { [ScheduledHapticEvent(time: 0.25, frame: safety.clamp($0))] } ?? []
    #expect(MIDIFileParser.hapticEvents(from: midi, safety: safety) == expected)
}

@Test(arguments: [0, 8, 10, 15], [36, 49, 51, 69])
func midiFileMelodicChannelsDoNotUseDrumProfiles(channel: Int, pitch: Int) throws {
    let midi = ParsedMIDIFile(notes: [parityNote(channel: channel, pitch: pitch)], durationSeconds: 1)
    let frequency = try MusicTheory.frequency(midi: pitch)
    let expected = HapticSafetyPolicy().clamp(.init(tones: [.init(frequencyHz: frequency)], durationMS: 120, level: 100.0 / 127))
    #expect(MIDIFileParser.hapticEvents(from: midi) == [.init(time: 0.25, frame: expected)])
}

@Test func midiFileHapticProjectionRejectsInvalidMutatedNotes() {
    let invalid = [parityNote(start: .nan), parityNote(start: .infinity), parityNote(start: -1),
                   parityNote(duration: .nan), parityNote(duration: .infinity), parityNote(duration: 0), parityNote(duration: -1),
                   parityNote(channel: -1), parityNote(channel: 16), parityNote(pitch: -1), parityNote(pitch: 128),
                   parityNote(velocity: 0), parityNote(velocity: -1), parityNote(velocity: 128)]
    let valid = parityNote(channel: 0, pitch: 69)
    let expected = MIDIFileParser.hapticEvents(from: .init(notes: [valid], durationSeconds: 1))
    #expect(expected.count == 1)
    for note in invalid {
        #expect(MIDIFileParser.hapticEvents(from: .init(notes: [note, valid], durationSeconds: 1)) == expected)
    }
}

@Test func midiFileHapticProjectionPreservesChronologicalOrder() {
    let notes = [parityNote(pitch: 51, start: 2), parityNote(channel: 0, pitch: 69, start: 1), parityNote(pitch: 36, start: 0)]
    let midi = ParsedMIDIFile(notes: notes, durationSeconds: 3)
    let events = MIDIFileParser.hapticEvents(from: midi)
    #expect(events.map(\.time) == [0, 1, 2])
    #expect(midi.notes == notes)
}
