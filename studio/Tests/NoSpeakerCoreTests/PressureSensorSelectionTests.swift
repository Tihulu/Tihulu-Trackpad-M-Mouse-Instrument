import Testing
@testable import NoSpeakerCore

@Test func experimentalClickPressureDoesNotSilentlyFallBackToContactSize() {
    var state = MIDIHelperSustainState()
    let settings = MIDIHelperSustainSettings(
        trackpadEnabled: true,
        trackpadContactThreshold: 0.6,
        trackpadGesture: .contactThreshold,
        trackpadSensor: .clickPressure
    )
    #expect(!state.update(
        trackpadContactSizes: [1.0], magicMouseTouching: false,
        settings: settings, trackpadClickDown: false
    ).isActive)
    #expect(!state.update(
        trackpadContactSizes: [1.0], magicMouseTouching: false,
        settings: settings, trackpadClickDown: true
    ).isActive)
    #expect(state.update(
        trackpadContactSizes: [0.05], magicMouseTouching: false,
        settings: settings, trackpadClickDown: true,
        trackpadClickPressure: 0.85
    ).isActive)
    #expect(!state.update(
        trackpadContactSizes: [0.05], magicMouseTouching: false,
        settings: settings, trackpadClickDown: false,
        trackpadClickPressure: 0
    ).isActive)
}

@Test func contactSizeRemainsDefaultSensorAndPressureIsIgnored() {
    var state = MIDIHelperSustainState()
    let settings = MIDIHelperSustainSettings(
        trackpadEnabled: true, trackpadContactThreshold: 0.5
    )
    #expect(settings.trackpadSensor == .contactSize)
    #expect(!state.update(
        trackpadContactSizes: [0.1], magicMouseTouching: false,
        settings: settings, trackpadClickDown: true,
        trackpadClickPressure: 1
    ).isActive)
    #expect(state.update(
        trackpadContactSizes: [0.75], magicMouseTouching: false,
        settings: settings
    ).isActive)
}

@Test func invalidClickPressureReadingCannotHoldNotes() {
    var state = MIDIHelperSustainState()
    let settings = MIDIHelperSustainSettings(
        trackpadEnabled: true, trackpadContactThreshold: 0.5,
        trackpadGesture: .contactThreshold,
        trackpadSensor: .clickPressure
    )
    #expect(!state.update(
        trackpadContactSizes: [0.8], magicMouseTouching: false,
        settings: settings, trackpadClickDown: true,
        trackpadClickPressure: .nan
    ).isActive)
}
