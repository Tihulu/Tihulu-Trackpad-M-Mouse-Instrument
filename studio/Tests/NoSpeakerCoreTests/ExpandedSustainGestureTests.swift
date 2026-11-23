import Testing
@testable import NoSpeakerCore

@Test func trackpadTouchHoldAndTapToggle() {
    var state = MIDIHelperSustainState()
    var settings = MIDIHelperSustainSettings(trackpadEnabled: true, trackpadGesture: .touchHold)
    #expect(state.update(trackpadContactSizes: [0.1], magicMouseTouching: false, settings: settings).trackpadActive)
    #expect(!state.update(trackpadContactSizes: [], magicMouseTouching: false, settings: settings).isActive)

    settings.trackpadGesture = .tapToggle
    #expect(state.update(trackpadContactSizes: [0.1], magicMouseTouching: false, settings: settings).isActive)
    #expect(state.update(trackpadContactSizes: [0.1], magicMouseTouching: false, settings: settings).isActive)
    #expect(state.update(trackpadContactSizes: [], magicMouseTouching: false, settings: settings).isActive)
    #expect(!state.update(trackpadContactSizes: [0.1], magicMouseTouching: false, settings: settings).isActive)
}

@Test func trackpadPhysicalClickHoldAndToggle() {
    var state = MIDIHelperSustainState()
    var settings = MIDIHelperSustainSettings(trackpadEnabled: true, trackpadGesture: .clickHold)
    #expect(!state.update(trackpadContactSizes: [0.3], magicMouseTouching: false, settings: settings).isActive)
    #expect(state.update(trackpadContactSizes: [], magicMouseTouching: false, settings: settings, trackpadClickDown: true).isActive)
    #expect(!state.update(trackpadContactSizes: [], magicMouseTouching: false, settings: settings, trackpadClickDown: false).isActive)

    settings.trackpadGesture = .clickToggle
    #expect(state.update(trackpadContactSizes: [], magicMouseTouching: false, settings: settings, trackpadClickDown: true).isActive)
    #expect(state.update(trackpadContactSizes: [], magicMouseTouching: false, settings: settings, trackpadClickDown: true).isActive)
    #expect(state.update(trackpadContactSizes: [], magicMouseTouching: false, settings: settings, trackpadClickDown: false).isActive)
    #expect(!state.update(trackpadContactSizes: [], magicMouseTouching: false, settings: settings, trackpadClickDown: true).isActive)
}

@Test func mousePhysicalClickAndSustainCombination() {
    var state = MIDIHelperSustainState()
    var settings = MIDIHelperSustainSettings(
        trackpadEnabled: true,
        magicMouseEnabled: true,
        magicMouseGesture: .clickHold,
        trackpadGesture: .touchHold
    )
    #expect(state.update(trackpadContactSizes: [0.2], magicMouseTouching: true, settings: settings).isActive)
    let both = state.update(trackpadContactSizes: [0.2], magicMouseTouching: true, settings: settings, magicMouseClickDown: true)
    #expect(both.trackpadActive && both.magicMouseActive)
    #expect(state.update(trackpadContactSizes: [], magicMouseTouching: true, settings: settings, magicMouseClickDown: true).isActive)
    #expect(!state.update(trackpadContactSizes: [], magicMouseTouching: true, settings: settings).isActive)

    settings.magicMouseGesture = .clickToggle
    #expect(state.update(trackpadContactSizes: [], magicMouseTouching: true, settings: settings, magicMouseClickDown: true).isActive)
    #expect(state.update(trackpadContactSizes: [], magicMouseTouching: false, settings: settings, magicMouseClickDown: false).isActive)
    #expect(!state.update(trackpadContactSizes: [], magicMouseTouching: true, settings: settings, magicMouseClickDown: true).isActive)
}

@Test func thresholdStillSupportedAndDisabledStaysOff() {
    var state = MIDIHelperSustainState()
    var settings = MIDIHelperSustainSettings(trackpadEnabled: true, trackpadContactThreshold: 0.6)
    #expect(!state.update(trackpadContactSizes: [0.59], magicMouseTouching: false, settings: settings).isActive)
    #expect(state.update(trackpadContactSizes: [0.9], magicMouseTouching: false, settings: settings).isActive)
    #expect(state.update(trackpadContactSizes: [0.55], magicMouseTouching: false, settings: settings).isActive)
    settings.trackpadEnabled = false
    #expect(!state.update(trackpadContactSizes: [1], magicMouseTouching: false, settings: settings).isActive)
    state.reset()
    #expect(!state.snapshot.isActive)
}

@Test func clickPressureNeverPretendsContactSizeIsActualForce() {
    var state = MIDIHelperSustainState()
    let settings = MIDIHelperSustainSettings(
        trackpadEnabled: true,
        trackpadContactThreshold: 0.6,
        trackpadGesture: .contactThreshold,
        trackpadSensor: .clickPressure
    )
    #expect(!state.update(
        trackpadContactSizes: [0.95], magicMouseTouching: false,
        settings: settings, trackpadClickDown: false
    ).isActive)
    #expect(!state.update(
        trackpadContactSizes: [0.95], magicMouseTouching: false,
        settings: settings, trackpadClickDown: true
    ).isActive)
    #expect(state.update(
        trackpadContactSizes: [0.1], magicMouseTouching: false,
        settings: settings, trackpadClickDown: true, trackpadClickPressure: 0.8
    ).isActive)
    #expect(!state.update(
        trackpadContactSizes: [0.1], magicMouseTouching: false,
        settings: settings, trackpadClickDown: false, trackpadClickPressure: 0
    ).isActive)
}
