import Foundation
import Testing
@testable import NoSpeakerCore

private func checkGeneratedHapticParity(_ c: MelodicPatternGenerator.Configuration) throws {
    let sequence = try MelodicPatternGenerator.generate(c)
    let events = try HapticPatternRenderer.notes(sequence)
    let clip = try MIDIClip.melody(sequence)
    #expect(events.count == sequence.steps.count)
    #expect(events.count == clip.notes.count)
    let strict = HapticSafetyPolicy(maxLevel: 0.35, minFrequencyHz: 150,
                                    maxFrequencyHz: 2000, maxTonesPerFrame: 1, maxFrameDurationMS: 40)
    for ((step, event), note) in zip(zip(sequence.steps, events), clip.notes) {
        let pitch = try #require(step.midi)
        let frequency = 440.0 * pow(2.0, Double(pitch - 69) / 12.0)
        #expect(note.pitch == pitch)
        #expect(abs(event.time - Double(note.start) * 60 / c.bpm / 960) < 1e-9)
        #expect(abs(event.frame.durationMS - c.gate * 15_000 / c.bpm) < 1e-9)
        // MIDI quantizes gate to integer ticks; haptic timing is continuous.
        #expect(abs(event.frame.durationMS - Double(note.duration) * 60_000 / c.bpm / 960) <= 30_000 / c.bpm / 960 + 1e-9)
        #expect(event.frame.level == step.velocity)
        #expect(event.frame.tones.count == 1)
        let tone = try #require(event.frame.tones.first)
        #expect(abs(tone.frequencyHz - frequency) < 1e-9)
        #expect(tone.amplitude == 1)
        for policy in [HapticSafetyPolicy(), strict] {
            for master in [0.0, 0.5, 1.0] {
                let result = HapticActuationAdmission.prepare(event.frame, masterLevel: master, safety: policy)
                if master == 0 {
                    #expect(result == .silent)
                } else {
                    guard case let .frame(admitted) = result else {
                        Issue.record("Expected bounded non-silent frame")
                        continue
                    }
                    #expect(admitted.tones == [.init(frequencyHz: min(max(frequency, policy.minFrequencyHz), policy.maxFrequencyHz))])
                    #expect(admitted.durationMS == min(max(event.frame.durationMS, 0.5), policy.maxFrameDurationMS))
                    #expect(admitted.level == min(step.velocity, policy.maxLevel) * master)
                }
            }
        }
    }
}

@Test(arguments: MelodicPatternGenerator.Genre.allCases, MelodicPatternGenerator.Role.allCases)
func generatedMelodyHapticAndMIDIShareNominalTiming(genre: MelodicPatternGenerator.Genre, role: MelodicPatternGenerator.Role) throws {
    for (bpm, gate, density): (Double, Double, Int) in [(20, 1, 100), (123.5, 0.673, 40), (300, 0.05, 0)] {
        var c = MelodicPatternGenerator.Configuration()
        c.genre = genre; c.role = role; c.bpm = bpm; c.gate = gate; c.density = density
        c.low = role == .bass ? 28 : 60; c.high = role == .bass ? 59 : 96
        c.bars = 2; c.complexity = 100; c.variation = 100; c.seed = 42
        try checkGeneratedHapticParity(c)
    }
}

@Test(arguments: [0, 127], MelodicPatternGenerator.Role.allCases)
func generatedMelodyExtremePitchesRespectActuationBounds(pitch: Int, role: MelodicPatternGenerator.Role) throws {
    for bpm in [20.0, 300.0] {
        for gate in [0.05, 1.0] {
            var c = MelodicPatternGenerator.Configuration()
            c.role = role; c.root = pitch % 12; c.low = pitch; c.high = pitch
            c.bpm = bpm; c.gate = gate; c.bars = 1; c.density = 100; c.velocity = 1
            try checkGeneratedHapticParity(c)
        }
    }
}
