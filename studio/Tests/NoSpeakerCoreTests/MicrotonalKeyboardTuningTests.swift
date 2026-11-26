import Testing
@testable import NoSpeakerCore

@Test func microtonalKeyboardQuarterTonesAreDistinctDegrees() throws {
    let tuning = try #require(MicrotonalKeyboardTuning.edo(24, rootMIDI: 69))
    let root = try #require(tuning.pitch(step: 0))
    let quarter = try #require(tuning.pitch(step: 1))
    let semitone = try #require(tuning.pitch(step: 2))
    #expect(root.frequency == 440)
    #expect(quarter.centsFromRoot == 50)
    #expect(semitone.centsFromRoot == 100)
    #expect(root.frequency < quarter.frequency && quarter.frequency < semitone.frequency)
    #expect(quarter.degree != root.degree)
    #expect(tuning.pitch(step: 24)?.frequency == 880)
}
@Test func microtonalKeyboardOtherEDOsAndNegativeSteps() throws {
    for count in [12, 19, 24, 31, 53, 128] {
        let t = try #require(MicrotonalKeyboardTuning.edo(count, rootMIDI: 69))
        let below = try #require(t.pitch(step: -1))
        #expect(below.degree == count - 1)
        #expect(below.octave == -1)
        #expect(abs(below.centsFromRoot + 1200 / Double(count)) < 0.000001)
        #expect(t.pitch(step: -count)?.frequency == 220)
    }
}
@Test func microtonalKeyboardCustomDegreesAndSparsePage() throws {
    let t = try #require(MicrotonalKeyboardTuning(degrees: [0, 22.6415, 90, 204, 498], rootMIDI: 60))
    let page = try #require(t.page(firstStep: 0, authorizedSlots: (1 << 2) | (1 << 10) | (1 << 24)))
    #expect(page.map(\.slot) == [2, 10, 24])
    #expect(page.map(\.pitch.centsFromRoot) == [0, 22.6415, 90])
    #expect(page.map(\.pitch.step) == [0, 1, 2])
    #expect(t.pitch(step: 5)?.centsFromRoot == 1200)
    #expect(t.page(firstStep: Int.max, authorizedSlots: 3) == nil)
    #expect(t.page(firstStep: 0, authorizedSlots: 0) == nil)
    #expect(t.page(firstStep: 0, authorizedSlots: 1 << 25) == nil)
}
@Test func microtonalKeyboardRejectsInvalidScaleAndOutOfRangePitch() throws {
    for degrees: [Double] in [[], [0], [1, 100], [0, 0], [0, 100, 90], [0, 1200], [0, .nan], [0, .infinity]] {
        #expect(MicrotonalKeyboardTuning(degrees: degrees) == nil)
    }
    #expect(MicrotonalKeyboardTuning.edo(1) == nil)
    #expect(MicrotonalKeyboardTuning.edo(129) == nil)
    #expect(MicrotonalKeyboardTuning.edo(24, referenceA4: .infinity) == nil)
    let low = try #require(MicrotonalKeyboardTuning.edo(24, rootMIDI: 0))
    let high = try #require(MicrotonalKeyboardTuning.edo(24, rootMIDI: 127))
    #expect(low.pitch(step: -1) == nil)
    #expect(high.pitch(step: 1) == nil)
    #expect(high.page(firstStep: 0, authorizedSlots: 3) == nil)
    #expect(low.pitch(step: Int.min) == nil)
}
