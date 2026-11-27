import Foundation
import Testing
@testable import NoSpeakerCore

private func represented(_ pitch: OfflineTuningMemberPitch) -> Double {
    let delta = Double(pitch.bend - 8192)
    return Double(pitch.anchor) + delta / (delta >= 0 ? 8191 : 8192) * Double(pitch.bendRangeSemitones)
}

@Test func importedMemberPitchPreservesReferenceAndCoincidentAnchors() throws {
    let profile = try ScalaKeyboardProfile(scaleText: "Dense\n4\n10.0\n20.0\n700.0\n2", mappingText: "0\n48\n84\n60\n60\n432\n4")
    let preview = profile.preview
    guard case .tuned(let a) = preview.memberOutput(60), case .tuned(let b) = preview.memberOutput(61) else {
        Issue.record("Expected two tuned members"); return
    }
    #expect(a.anchor == b.anchor)
    #expect(a.bend != b.bend)
    #expect(a.inputNote != b.inputNote && a.step != b.step)
    #expect(abs(440 * pow(2, (represented(a) - 69) / 12) - 432) < 0.01)
    #expect(abs((represented(b) - represented(a)) * 100 - 10) < 0.03)
}

@Test func importedMemberProjectionNeverEmitsUnassignedKeys() throws {
    let preview = try ScalaKeyboardProfile(scaleText: "Test\n3\n100.0\n700.0\n2", mappingText: "3\n48\n84\n60\n60\n440\n3\n0\nx\n2").preview
    #expect(preview.memberOutput(61) == .unmapped)
    #expect(preview.memberOutput(47) == .outsideRange)
    #expect(preview.memberOutput(85) == .outsideRange)
    #expect(preview.memberOutput(-1) == .unavailable)
    #expect(preview.memberOutput(128) == .unavailable)
    for range in [Int.min, 0, 97, Int.max] {
        #expect(preview.memberOutput(60, bendRangeSemitones: range) == .unavailable)
    }
    let wide = try ScalaKeyboardProfile(scaleText: "Wide\n2\n700.0\n2", mappingText: "0\n0\n127\n60\n60\n440\n2").preview
    #expect(wide.memberOutput(127) == .unavailable)
}

@Test func offlineMemberQuantizationBoundAcrossAllKeysAndBendRanges() throws {
    let tuning = try #require(MicrotonalKeyboardTuning.edo(24, rootMIDI: 60, referenceA4: 432))
    for note in 0...127 {
        let pitch = try #require(tuning.pitch(step: note - 60))
        let expected = 69 + 12 * log2(pitch.frequency / 440)
        for range in [1, 2, 48, 96] {
            let member = try #require(OfflineTuningMemberPitch.encode(inputNote: note, pitch: pitch, bendRangeSemitones: range))
            #expect(member.inputNote == note && member.step == pitch.step)
            #expect((0...127).contains(member.anchor) && (0...16383).contains(member.bend))
            #expect(abs(represented(member) - expected) <= Double(range) / 8191 / 2 + 1e-9)
        }
    }
}
