import Foundation
import Testing
@testable import NoSpeakerCore

@Test func nativeRelativeManualSettingsUseIndependentWireReferencesAndEnabledLanes() throws {
    let settings = NativeHelperRelativeManualSettings(x: .init(reference: 0.5, gain: 2),
        y: .init(reference: 0.7, gain: 0.5), contactSize: .init(reference: 0.25, gain: 4), smoothingMS: 20)
    let lanes = try #require(settings.lanes(enabled: [.x, .y]))
    #expect(lanes.count == 2 && lanes[.contactSize] == nil)
    #expect(lanes[.x]?.reference == 8192 && lanes[.x]?.upper == 16383 && lanes[.x]?.gain == 2)
    #expect(lanes[.y]?.reference == 89 && lanes[.y]?.upper == 127 && lanes[.y]?.gain == 0.5)
    #expect(lanes[.x]?.smoothingMS == 20 && lanes[.y]?.smoothingMS == 20)
    let size = try #require(settings.lanes(enabled: [.contactSize]))
    #expect(size[.contactSize]?.reference == 32 && size[.contactSize]?.gain == 4)
}

@Test func nativeRelativeManualSettingsRejectInvalidAndUnverifiedReferenceSources() {
    var settings = NativeHelperRelativeManualSettings()
    #expect(settings.isValid && settings.lanes(enabled: []) == nil)
    settings.x.reference = .nan
    #expect(!settings.isValid && settings.lanes(enabled: [.y]) == nil)
    settings = .init(); settings.y.gain = 4.001
    #expect(!settings.isValid)
    settings = .init(); settings.contactSize.referenceSource = .receiverConfirmed
    #expect(!settings.isValid && settings.lanes(enabled: [.contactSize]) == nil)
    settings = .init(); settings.x.referenceSource = .lastDelivered
    #expect(!settings.isValid)
    settings = .init(); settings.smoothingMS = 251
    #expect(!settings.isValid)
}

@Test func nativeRelativeManualSettingsRoundTripAndDefaultBendCenter() throws {
    let settings = NativeHelperRelativeManualSettings()
    let encoded = try JSONEncoder().encode(settings)
    #expect(try JSONDecoder().decode(NativeHelperRelativeManualSettings.self, from: encoded) == settings)
    let lanes = try #require(settings.lanes(enabled: [.x, .y, .contactSize]))
    #expect(lanes[.x]?.reference == 8192 && lanes[.y]?.reference == 0 && lanes[.contactSize]?.reference == 127)
}
