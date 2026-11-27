import Foundation
import Testing
@testable import NoSpeakerCore

struct RelativeReferenceEvidenceBoundaryTests {
    @Test(arguments: [RelativeReferenceSource.manual, .lastDelivered, .receiverConfirmed],
          [RelativeReferenceSource.manual, .lastDelivered, .receiverConfirmed])
    func sourceAndWireBounds(source: RelativeReferenceSource, expected: RelativeReferenceSource) {
        let ranges = [(0, 0), (0, 127), (0, 16383), (64, 64), (64, 127), (8192, 16383),
                      (-1, 127), (0, 16384), (128, 127), (Int.min, Int.max), (Int.max, Int.min)]
        let values = [Int.min, -1, 0, 1, 63, 64, 65, 126, 127, 128, 8191, 8192, 8193, 16382, 16383, 16384, Int.max]
        for (lower, upper) in ranges {
            for value in values {
                let evidence = RelativeReferenceEvidence(source: source, value: value, observedAt: 1)
                let validRange = lower >= 0 && upper <= 16383 && lower <= upper
                let permitted = source == expected && source != .manual && validRange && value >= lower && value <= upper
                #expect(evidence.permits(source: expected, lower: lower, upper: upper, now: 1) == permitted)
            }
        }
    }

    @Test(arguments: [RelativeReferenceSource.lastDelivered, .receiverConfirmed],
          [0.0, 1.0, 1024.0, 1048576.0, 1073741824.0, 1099511627776.0])
    func adjacentClockBoundaries(source: RelativeReferenceSource, observed: Double) {
        let evidence = RelativeReferenceEvidence(source: source, value: 64, observedAt: observed)
        let deadline = observed + 0.25
        #expect(!evidence.permits(source: source, lower: 0, upper: 127, now: observed.nextDown))
        for now in [observed, observed.nextUp, deadline.nextDown, deadline] {
            #expect(evidence.permits(source: source, lower: 0, upper: 127, now: now))
        }
        for now in [deadline.nextUp, deadline + 1, Double.nan, .infinity, -.infinity] {
            #expect(!evidence.permits(source: source, lower: 0, upper: 127, now: now))
        }
        for invalid in [-1.0, Double.nan, .infinity, -.infinity] {
            let bad = RelativeReferenceEvidence(source: source, value: 64, observedAt: invalid)
            for now in [observed, deadline, Double.nan, .infinity, -.infinity] {
                #expect(!bad.permits(source: source, lower: 0, upper: 127, now: now))
            }
        }
    }
}
