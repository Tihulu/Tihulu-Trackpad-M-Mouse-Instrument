import Foundation
import Testing
@testable import NoSpeakerCore

struct RelativeGestureCadenceTests {
    @Test(arguments: [127, 16383], [0, 1, 25, 100, 250])
    func constantInputUsesElapsedTime(upper: Int, smoothing: Int) throws {
        for gain in [0.25, 1.0, 4.0] {
            for reference in [0, upper / 2, upper] {
                for target in [0.0, 0.125, 0.875, 1.0] {
                    for duration in [0.015625, 0.125, 0.5, 2.0] {
                        for partitions in [1, 2, 8, 32] {
                            var gesture = try #require(RelativeControlGesture(input: 0.5, timestamp: 1,
                                reference: reference, lower: 0, upper: upper, gain: gain, smoothingMS: smoothing))
                            var wire = reference
                            for index in 1...partitions {
                                if let next = gesture.update(input: target,
                                    timestamp: 1 + duration * Double(index) / Double(partitions)) {
                                    #expect(next != wire)
                                    #expect((0...upper).contains(next))
                                    wire = next
                                }
                            }
                            let alpha = smoothing == 0 ? 1.0 : 1 - exp(-duration * 1000 / Double(smoothing))
                            let raw = Double(reference) + (target - 0.5) * alpha * Double(upper) * gain
                            let expected = Int(min(Double(upper), max(0, raw)).rounded())
                            // Floating-point partitioning may differ at an exact half-wire tie.
                            #expect(abs(wire - expected) <= 1)
                            if let restored = gesture.update(input: 0.5, timestamp: 1 + duration + 20) {
                                wire = restored
                            }
                            #expect(wire == reference)
                        }
                    }
                }
            }
        }
    }

    @Test(arguments: [127, 16383], [0, 1, 25, 100, 250])
    func invalidSamplesCannotChangeNextOutput(upper: Int, smoothing: Int) throws {
        for gain in [0.25, 1.0, 4.0] {
            for reference in [0, upper / 2, upper] {
                for invalid in [(Double.nan, 1.125), (.infinity, 1.125), (-0.01, 1.125),
                                (1.01, 1.125), (0.9, Double.nan), (0.9, .infinity), (0.9, 0.5)] {
                    var clean = try #require(RelativeControlGesture(input: 0.5, timestamp: 1,
                        reference: reference, lower: 0, upper: upper, gain: gain, smoothingMS: smoothing))
                    var challenged = clean
                    let initial = clean.update(input: 0.75, timestamp: 1.0625)
                    #expect(challenged.update(input: 0.75, timestamp: 1.0625) == initial)
                    #expect(challenged.update(input: invalid.0, timestamp: invalid.1) == nil)
                    for (input, time) in [(0.25, 1.25), (0.95, 1.5), (0.5, 1.75), (0.5, 20.0)] {
                        let expected = clean.update(input: input, timestamp: time)
                        #expect(challenged.update(input: input, timestamp: time) == expected)
                    }
                }
            }
        }
    }
}
