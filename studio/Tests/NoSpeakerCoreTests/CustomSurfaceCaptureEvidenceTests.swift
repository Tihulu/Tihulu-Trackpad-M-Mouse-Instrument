import Testing
@testable import NoSpeakerCore

@Test func customCaptureEvidenceSeparatesOccupiedGapsAndInvalidRecords() {
    var e = CustomSurfaceCaptureEvidence()
    e.observe(receipt: 0, rawCount: 0, rawStates: [], decodedCount: 0, occupied: false)
    e.observe(receipt: 1_000_000_000, rawCount: 1, rawStates: [4], decodedCount: 1, occupied: true)
    e.observe(receipt: 1_100_000_000, rawCount: 1, rawStates: [4], decodedCount: 1, occupied: true)
    e.observe(receipt: 1_250_000_000, rawCount: 2, rawStates: [5, 7], decodedCount: 1, occupied: nil)
    #expect(e.frames == 4 && e.neutralFrames == 1 && e.occupiedFrames == 2)
    #expect(e.invalidFrames == 1 && e.incompleteFrames == 1)
    #expect(e.maximumGapNS == 1_000_000_000)
    #expect(e.maximumOccupiedGapNS == 150_000_000 && e.occupiedDeadlineGaps == 1)
    #expect(e.stateCounts[4] == 2 && e.stateCounts[5] == 1 && e.stateCounts[7] == 1)
}

@Test func customCaptureEvidenceBoundsUnknownStatesAndRejectsRegressingClock() {
    var e = CustomSurfaceCaptureEvidence()
    e.observe(receipt: 10, rawCount: 99, rawStates: Array(repeating: Int.max, count: 99),
              decodedCount: 0, occupied: nil)
    e.observe(receipt: 9, rawCount: nil, rawStates: [-1], decodedCount: 0, occupied: nil)
    e.observe(receipt: 11, rawCount: 0, rawStates: [], decodedCount: 0, occupied: false)
    #expect(e.stateCounts.count == 17 && e.stateCounts[16] == 33)
    #expect(e.unorderedReceipts == 1 && e.maximumGapNS == 1)
    #expect(e.incompleteFrames == 2 && e.invalidFrames == 2)
}

@Test func customCaptureEvidenceReportsTerminalOccupiedSilenceSeparately() {
    var e = CustomSurfaceCaptureEvidence()
    e.observe(receipt: 100, rawCount: 1, rawStates: [4], decodedCount: 1, occupied: true)
    e.finish(at: 99)
    #expect(e.trailingOccupiedGapNS == 0)
    e.finish(at: 150_000_100)
    #expect(e.trailingOccupiedGapNS == 150_000_000)
    #expect(e.occupiedDeadlineGaps == 0 && e.maximumOccupiedGapNS == 0)
    var idle = CustomSurfaceCaptureEvidence()
    idle.observe(receipt: 0, rawCount: 0, rawStates: [], decodedCount: 0, occupied: false)
    idle.finish(at: 1_000_000_000)
    #expect(idle.trailingOccupiedGapNS == 0)
}
