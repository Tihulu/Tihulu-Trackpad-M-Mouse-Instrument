import Foundation
import Testing
@testable import NoSpeakerCore

struct RelativeManualWireRoundTripTests {
    @Test(arguments: NativeHelperRelativeClutch.Axis.allCases, [false, true])
    func normalizedReferenceRoundTripsEveryWireValue(axis: NativeHelperRelativeClutch.Axis, explicit: Bool) throws {
        let upper = axis == .x ? 16383 : 127
        let axes = NativeHelperRelativeClutch.Axis.allCases
        for value in 0...upper {
            var settings = NativeHelperRelativeManualSettings(smoothingMS: 250)
            let lane = RelativeControlSettings(reference: Double(value) / Double(upper), gain: 4,
                                               referenceSource: explicit ? .manual : nil)
            switch axis {
            case .x: settings.x = lane
            case .y: settings.y = lane
            case .contactSize: settings.contactSize = lane
            }
            for mask in 1...7 {
                let enabled = Set(axes.enumerated().compactMap { (mask & (1 << $0.offset)) != 0 ? $0.element : nil })
                let lanes = try #require(settings.lanes(enabled: enabled))
                #expect(Set(lanes.keys) == enabled)
                if enabled.contains(axis) {
                    let mapped = try #require(lanes[axis])
                    #expect(mapped.reference == value)
                    #expect(mapped.lower == 0 && mapped.upper == upper)
                    #expect(mapped.gain == 4 && mapped.smoothingMS == 250)
                }
            }
        }
    }

    @Test(arguments: NativeHelperRelativeClutch.Axis.allCases)
    func legacyManualDecodingAndFeedbackRejection(axis: NativeHelperRelativeClutch.Axis) throws {
        let legacy = Data(#"{"x":{"reference":0.5,"gain":1},"y":{"reference":0.25,"gain":0.5},"contactSize":{"reference":0.75,"gain":4},"smoothingMS":25}"#.utf8)
        let decoded = try JSONDecoder().decode(NativeHelperRelativeManualSettings.self, from: legacy)
        #expect(decoded.isValid)
        #expect(decoded.x.referenceSource == nil && decoded.y.referenceSource == nil && decoded.contactSize.referenceSource == nil)
        #expect(try JSONDecoder().decode(NativeHelperRelativeManualSettings.self, from: JSONEncoder().encode(decoded)) == decoded)
        for source in [RelativeReferenceSource.manual, .lastDelivered, .receiverConfirmed] {
            var settings = decoded
            switch axis {
            case .x: settings.x.referenceSource = source
            case .y: settings.y.referenceSource = source
            case .contactSize: settings.contactSize.referenceSource = source
            }
            let restored = try JSONDecoder().decode(NativeHelperRelativeManualSettings.self, from: JSONEncoder().encode(settings))
            #expect(restored == settings)
            for other in NativeHelperRelativeClutch.Axis.allCases {
                #expect((restored.lanes(enabled: [other]) != nil) == (source == .manual))
            }
            #expect(restored.lanes(enabled: []) == nil)
        }
    }
}
