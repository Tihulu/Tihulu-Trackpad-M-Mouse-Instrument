import Foundation
import Testing
@testable import NoSpeakerCore

private func expressionBase(bend: Int = 9216, range: Int = 2, note: Int = 60) -> OfflineTuningMemberPitch {
    .init(inputNote: note, step: note - 60, anchor: note, bend: bend, bendRangeSemitones: range)
}

@Test func memberExpressionRestoresFrozenMicrotonalBaseAndDoesNotAccumulate() {
    let base = expressionBase()
    guard case .projected(let up) = OfflineTuningExpression.member(base: base, offsetCents: 30),
          case .projected(let down) = OfflineTuningExpression.member(base: base, offsetCents: -70),
          case .projected(let neutral) = OfflineTuningExpression.member(base: base, offsetCents: 0) else {
        Issue.record("Expected bounded member projections"); return
    }
    #expect(up.base == base && down.base == base && neutral.base == base)
    #expect(up.expressiveBend > base.bend && down.expressiveBend < base.bend)
    #expect(abs(up.representedOffsetCents - 30) <= 0.013)
    #expect(abs(down.representedOffsetCents + 70) <= 0.013)
    #expect(neutral.expressiveBend == base.bend && neutral.representedOffsetCents == 0)
    #expect(OfflineTuningExpression.member(base: base, offsetCents: 30) == .projected(up))
}

@Test func memberExpressionRejectsOverflowInsteadOfChangingAnchorOrVoice() {
    let high = expressionBase(bend: 16383)
    let low = expressionBase(bend: 0)
    #expect(OfflineTuningExpression.member(base: high, offsetCents: 0.01) == .exceedsMemberRange)
    #expect(OfflineTuningExpression.member(base: low, offsetCents: -0.01) == .exceedsMemberRange)
    #expect(OfflineTuningExpression.member(base: high, offsetCents: -400) == .projected(.init(base: high, expressiveBend: 0, representedOffsetCents: -400)))
    #expect(OfflineTuningExpression.member(base: low, offsetCents: 400) == .projected(.init(base: low, expressiveBend: 16383, representedOffsetCents: 400)))
    for offset in [Double.nan, .infinity, -.infinity] {
        #expect(OfflineTuningExpression.member(base: high, offsetCents: offset) == .invalid)
    }
    #expect(OfflineTuningExpression.member(base: high, offsetCents: .greatestFiniteMagnitude) == .exceedsMemberRange)
    #expect(OfflineTuningExpression.member(base: expressionBase(bend: -1), offsetCents: 0) == .invalid)
    #expect(OfflineTuningExpression.member(base: expressionBase(range: 0), offsetCents: 0) == .invalid)
    #expect(OfflineTuningExpression.member(base: expressionBase(note: 128), offsetCents: 0) == .invalid)
}

@Test func zoneMasterExpressionKeepsDifferentMemberBasesAndRangesSeparate() throws {
    let tuned = expressionBase(bend: 9216, range: 2, note: 60)
    let original = expressionBase(bend: 8192, range: 2, note: 61)
    let neutral = try #require(OfflineTuningExpression.zone(base: tuned, masterBend: 8192, masterRangeSemitones: 48))
    let a = try #require(OfflineTuningExpression.zone(base: tuned, masterBend: 10240, masterRangeSemitones: 48))
    let b = try #require(OfflineTuningExpression.zone(base: original, masterBend: 10240, masterRangeSemitones: 48))
    #expect(a.base == tuned && b.base == original)
    #expect(b.base.anchor == b.base.inputNote && b.base.bend == 8192)
    #expect(a.masterBend == b.masterBend && a.masterRangeSemitones == 48)
    #expect(abs(a.predictedPitchFromAnchorCents - b.predictedPitchFromAnchorCents - neutral.predictedPitchFromAnchorCents) < 1e-9)
    #expect(abs(b.predictedPitchFromAnchorCents - 1200) < 0.2)
    let originalNeutral = try #require(OfflineTuningExpression.zone(base: original, masterBend: 8192, masterRangeSemitones: 48))
    #expect(originalNeutral.predictedPitchFromAnchorCents == 0)
    #expect(OfflineTuningExpression.zone(base: tuned, masterBend: -1, masterRangeSemitones: 48) == nil)
    #expect(OfflineTuningExpression.zone(base: tuned, masterBend: 16384, masterRangeSemitones: 48) == nil)
    #expect(OfflineTuningExpression.zone(base: tuned, masterBend: 8192, masterRangeSemitones: 97) == nil)
}

@Test func memberExpressionHonorsExactHeadroomAndRefusesAdjacentOutsideOffsets() throws {
    for range in 1...96 {
        for bend in [0, 1, 4096, 8191, 8192, 8193, 10490, 16382, 16383] {
            let base = expressionBase(bend: bend, range: range)
            let neutral = try #require(OfflineTuningExpression.zone(base: base, masterBend: 8192, masterRangeSemitones: range))
            let cents = neutral.predictedPitchFromAnchorCents
            let limit = Double(range) * 100
            let upper = limit - cents, lower = -limit - cents
            #expect(OfflineTuningExpression.member(base: base, offsetCents: upper) == .projected(.init(base: base, expressiveBend: 16383, representedOffsetCents: upper)))
            #expect(OfflineTuningExpression.member(base: base, offsetCents: lower) == .projected(.init(base: base, expressiveBend: 0, representedOffsetCents: lower)))
            #expect(OfflineTuningExpression.member(base: base, offsetCents: upper.nextUp) == .exceedsMemberRange)
            #expect(OfflineTuningExpression.member(base: base, offsetCents: lower.nextDown) == .exceedsMemberRange)
        }
    }
}

@Test func memberExpressionAcceptsReadinessHeadroomWithoutRangeExpansion() throws {
    let preview = try ScalaKeyboardProfile(scaleText: "Dense\n4\n10.0\n20.0\n700.0\n2", mappingText: "4\n56\n67\n60\n60\n432\n4\n0\n1\n2\nx").preview
    for range in [1, 2, 48, 96] {
        let report = try #require(ScalaKeyboardReadiness(preview: preview, bendRangeSemitones: range))
        for entry in report.entries {
            guard case .projected(let projection) = entry.disposition else { continue }
            let base = projection.member
            let up = projection.upwardHeadroomCents, down = -projection.downwardHeadroomCents
            #expect(OfflineTuningExpression.member(base: base, offsetCents: up) == .projected(.init(base: base, expressiveBend: 16383, representedOffsetCents: up)))
            #expect(OfflineTuningExpression.member(base: base, offsetCents: down) == .projected(.init(base: base, expressiveBend: 0, representedOffsetCents: down)))
            #expect(OfflineTuningExpression.member(base: base, offsetCents: up.nextUp) == .exceedsMemberRange)
            #expect(OfflineTuningExpression.member(base: base, offsetCents: down.nextDown) == .exceedsMemberRange)
        }
    }
}
