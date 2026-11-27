import Testing
@testable import NoSpeakerCore

private typealias Axis = NativeHelperRelativeClutch.Axis
private typealias Configuration = NativeHelperRelativeSingleChannel
private typealias Preflight = NativeHelperRelativeManualPreflight

@Test func relativeManualConfigurationSnapshotAndWireWidths() throws {
    var settings = NativeHelperRelativeManualSettings(x: .init(reference: 0.5, gain: 2), y: .init(reference: 0.25), contactSize: .init(reference: 0.75), smoothingMS: 25)
    let config = try #require(Configuration(settings: settings, enabled: [.x, .y, .contactSize], channel: 15, vibratoCC: 1, expressionCC: 11))
    settings.x.reference = 0
    settings.smoothingMS = 0
    #expect(config.channel == 15)
    #expect(config.configuration.lanes[.x]?.reference == 8192)
    #expect(config.configuration.lanes[.x]?.upper == 16383)
    #expect(config.configuration.lanes[.x]?.gain == 2)
    #expect(config.configuration.lanes[.y]?.reference == 32)
    #expect(config.configuration.lanes[.contactSize]?.reference == 95)
    #expect(config.configuration.lanes[.contactSize]?.upper == 127)
    #expect(config.configuration.lanes[.x]?.smoothingMS == 25)
    #expect(config.configuration.plan.targetDestinations == [.init(.pitchBend, channel: 15), .init(.controlChange, channel: 15, number: 1), .init(.controlChange, channel: 15, number: 11)])
}

@Test func relativeManualPreflightRejectsMismatchedAxisAndTargetShape() {
    let bend = SensorDestination(.pitchBend, channel: 0)
    let cc = SensorDestination(.controlChange, channel: 0, number: 1)
    #expect(Preflight(settings: .init(), enabled: [.x], targets: [.x: cc]) == nil)
    #expect(Preflight(settings: .init(), enabled: [.y], targets: [.y: bend]) == nil)
    #expect(Preflight(settings: .init(), enabled: [.contactSize], targets: [.contactSize: bend]) == nil)
    #expect(Preflight(settings: .init(), enabled: [.x], targets: [.x: bend, .y: cc]) == nil)
    #expect(Preflight(settings: .init(), enabled: [.x, .y], targets: [.x: bend]) == nil)
    #expect(Preflight(settings: .init(), enabled: [], targets: [:]) == nil)
    // Generic plan is intentionally axis-agnostic, unlike this first manual UI.
    #expect(NativeHelperRelativeOutputPlan(targets: [.x: cc]) != nil)
}

@Test(arguments: Array(-1...16)) func relativeManualChannelValidation(channel: Int) {
    let config = Configuration(settings: .init(), enabled: [.x], channel: channel, vibratoCC: -1, expressionCC: 128)
    #expect((config != nil) == (0...15).contains(channel))
    if let config {
        #expect(config.configuration.plan.targetDestinations == [.init(.pitchBend, channel: channel)])
        #expect(Set(config.configuration.lanes.keys) == [.x])
    }
}

@Test(arguments: [NativeHelperRelativeClutch.Axis.y, .contactSize]) func relativeManualUsesExistingTargetPolicy(axis: NativeHelperRelativeClutch.Axis) {
    for cc in -1...128 {
        let target = SensorDestination(.controlChange, channel: 0, number: cc)
        let expected = ContinuousResponse.permitsRelative(target) && HelperCCPolicy.permits(cc)
        let config = Configuration(settings: .init(), enabled: [axis], channel: 0,
                                   vibratoCC: axis == .y ? cc : -1, expressionCC: axis == .contactSize ? cc : 128)
        #expect((config != nil) == expected)
        if let config {
            #expect(config.configuration.plan.targetDestinations == [target])
            #expect(config.configuration.lanes[axis]?.upper == 127)
        }
    }
}

@Test func relativeManualRejectsDuplicateEnabledCCAndIgnoresInactiveCC() {
    #expect(Configuration(settings: .init(), enabled: [.y, .contactSize], channel: 0, vibratoCC: 1, expressionCC: 1) == nil)
    #expect(Configuration(settings: .init(), enabled: [.y], channel: 0, vibratoCC: 1, expressionCC: 1) != nil)
    #expect(Configuration(settings: .init(), enabled: [.contactSize], channel: 0, vibratoCC: 128, expressionCC: 11) != nil)
    #expect(Configuration(settings: .init(), enabled: [], channel: 0, vibratoCC: 1, expressionCC: 11) == nil)
    for cc in [0, 6, 32, 38, 64, 65, 66, 67, 68, 69, 96, 97, 98, 99, 100, 101, 120, 127] {
        #expect(Configuration(settings: .init(), enabled: [.y], channel: 0, vibratoCC: cc, expressionCC: 11) == nil)
    }
}

@Test func relativeManualKeepsExistingSettingsValidation() {
    var settings = NativeHelperRelativeManualSettings()
    settings.smoothingMS = 251
    #expect(Configuration(settings: settings, enabled: [.x], channel: 0, vibratoCC: 1, expressionCC: 11) == nil)
    settings = .init(); settings.x.reference = .nan
    #expect(Configuration(settings: settings, enabled: [.x], channel: 0, vibratoCC: 1, expressionCC: 11) == nil)
    settings = .init(); settings.y.referenceSource = .receiverConfirmed
    #expect(Configuration(settings: settings, enabled: [.y], channel: 0, vibratoCC: 1, expressionCC: 11) == nil)
}
