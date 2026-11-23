import Testing
@testable import NoSpeakerCore

@Test func a4Is440Hz() throws {
    #expect(try MusicTheory.midiNumber(note: "A4") == 69)
    #expect(abs(try MusicTheory.frequency(note: "A4") - 440) < 0.0001)
}

@Test func noteRoundTrip() throws {
    #expect(try MusicTheory.noteName(midi: 60) == "C4")
    #expect(try MusicTheory.midiNumber(note: "C#4") == 61)
    #expect(try MusicTheory.midiNumber(note: "Db4") == 61)
}

@Test func sequencerProducesSortedEvents() throws {
    let sequence = NoteSequence(
        bpm: 120,
        stepsPerBeat: 4,
        length: 16,
        steps: [
            NoteStep(index: 8, midi: 69),
            NoteStep(index: 0, midi: 60)
        ]
    )
    let events = try HapticPatternRenderer.notes(sequence)
    #expect(events.count == 2)
    #expect(events[0].time == 0)
    #expect(events[1].time > events[0].time)
}

@Test func gmDrumMappingWorks() {
    #expect(MIDIDrumMap.voice(for: 36) == .kick)
    #expect(MIDIDrumMap.voice(for: 38) == .snare)
    #expect(MIDIDrumMap.voice(for: 42) == .closedHat)
    #expect(MIDIDrumMap.voice(for: 46) == .openHat)
}

@Test func safetyPolicyClampsFrames() {
    let policy = HapticSafetyPolicy()
    let frame = HapticFrame(
        tones: [HapticTone(frequencyHz: 10, amplitude: 2)],
        durationMS: 900,
        level: 4
    )
    let safe = policy.clamp(frame)
    #expect(safe.tones[0].frequencyHz == 98)
    #expect(safe.tones[0].amplitude == 1)
    #expect(safe.durationMS == 120)
    #expect(safe.level == 1)
}
