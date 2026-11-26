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

@Test func scientificPitchRoundTripsEveryMIDIKey() throws {
    for midi in 0...127 {
        let label = try MusicTheory.noteName(midi:midi)
        #expect(try MusicTheory.midiNumber(note:label) == midi)
    }
    #expect(try MusicTheory.midiNumber(note:"C-1") == 0)
    #expect(try MusicTheory.midiNumber(note:"D♭-1") == 1)
    #expect(try MusicTheory.midiNumber(note:"F♯9") == 126)
}
@Test func scientificPitchRejectsMalformedAndOverflowingOctaves() {
    for note in ["C--1","C1-2","C","C#","C\(Int.max)","C\(Int.min)","C999999999999999999999999999"] {
        #expect(throws: MusicTheoryError.self) { try MusicTheory.midiNumber(note:note) }
    }
    #expect(throws: MusicTheoryError.midiOutOfRange(132)) { try MusicTheory.midiNumber(note:"C10") }
    #expect(throws: MusicTheoryError.midiOutOfRange(-12)) { try MusicTheory.midiNumber(note:"C-2") }
}
