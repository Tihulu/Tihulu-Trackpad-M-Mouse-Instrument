import Foundation
import Testing
@testable import NoSpeakerCore

@Test func scalaReadinessAccountsForAllKeysAndReferenceError() throws {
    let preview = try ScalaKeyboardProfile(scaleText: "Sparse\n3\n100.0\n700.0\n2", mappingText: "3\n48\n72\n60\n60\n432\n3\n0\nx\n2").preview
    let report = try #require(ScalaKeyboardReadiness(preview: preview))
    #expect(report.entries.map(\.inputNote) == Array(0...127))
    #expect(report.projectedCount == 17 && report.unmappedCount == 8 && report.outsideRangeCount == 103)
    #expect(report.unavailablePitchCount == 0 && report.unavailableMemberCount == 0)
    #expect(report.entries[61].disposition == .unmapped)
    #expect(report.entries[85].disposition == .outsideRange)
    #expect(report.reference == report.entries[60])
    guard case .projected(let reference) = report.reference.disposition else {
        Issue.record("Missing projected reference"); return
    }
    #expect(abs(reference.targetHz - 432) < 1e-8)
    #expect(abs(reference.errorCents) <= 100.0 / 8191 + 1e-8)
    #expect(abs(reference.downwardHeadroomCents + reference.upwardHeadroomCents - 400) < 1e-9)
    let maxError = try #require(report.maximumAbsoluteErrorCents)
    #expect(maxError <= 100.0 / 8191 + 1e-8)
}

@Test func scalaReadinessSeparatesCoincidentAnchorsAndUnavailablePitch() throws {
    let dense = try ScalaKeyboardProfile(scaleText: "Dense\n4\n10.0\n20.0\n700.0\n2", mappingText: "0\n60\n63\n60\n60\n432\n4").preview
    let report = try #require(ScalaKeyboardReadiness(preview: dense, bendRangeSemitones: 48))
    #expect(report.projectedCount == 4 && report.outsideRangeCount == 124)
    let cluster = try #require(report.coincidentAnchors.first { $0.inputNotes.contains(60) })
    #expect(cluster.inputNotes == [60, 61, 62] && cluster.distinctStepCount == 3)
    let wide = try ScalaKeyboardProfile(scaleText: "Wide\n2\n700.0\n2", mappingText: "0\n0\n127\n60\n60\n440\n2").preview
    let wideReport = try #require(ScalaKeyboardReadiness(preview: wide))
    #expect(wideReport.unavailablePitchCount > 0)
    #expect(wideReport.entries[127].disposition == .unavailablePitch)
    #expect(wideReport.projectedCount + wideReport.unavailablePitchCount == 128)
    for invalid in [Int.min, 0, 97, Int.max] {
        #expect(ScalaKeyboardReadiness(preview: dense, bendRangeSemitones: invalid) == nil)
    }
}
