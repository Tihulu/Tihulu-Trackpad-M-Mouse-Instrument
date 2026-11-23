import Testing
@testable import NoSpeakerCore

@Test func sustainIsDisabledByDefault() {
    var engine = MIDIHelperSustainState()
    let settings = MIDIHelperSustainSettings()
    let active = engine.update(
        trackpadContactSizes: [0.9],
        magicMouseTouching: true,
        settings: settings
    )
    #expect(!active.isActive)
}

@Test func trackpadSustainUsesContactThresholdWithHysteresis() {
    var engine = MIDIHelperSustainState()
    let settings = MIDIHelperSustainSettings(
        trackpadEnabled: true,
        trackpadContactThreshold: 0.55
    )
    #expect(!engine.update(trackpadContactSizes: [0.54], magicMouseTouching: false, settings: settings).isActive)
    #expect(engine.update(trackpadContactSizes: [0.8, 0.6], magicMouseTouching: false, settings: settings).trackpadActive)
    #expect(engine.update(trackpadContactSizes: [0.5], magicMouseTouching: false, settings: settings).trackpadActive)
    #expect(!engine.update(trackpadContactSizes: [0.4], magicMouseTouching: false, settings: settings).trackpadActive)
    #expect(engine.update(trackpadContactSizes: [0.75], magicMouseTouching: false, settings: settings).isActive)
    #expect(!engine.update(trackpadContactSizes: [], magicMouseTouching: false, settings: settings).isActive)
}

@Test func magicMouseTouchHoldReleasesWhenLastFingerLifts() {
    var engine = MIDIHelperSustainState()
    let settings = MIDIHelperSustainSettings(
        magicMouseEnabled: true,
        magicMouseGesture: .touchHold
    )
    #expect(engine.update(trackpadContactSizes: [], magicMouseTouching: true, settings: settings).magicMouseActive)
    #expect(engine.update(trackpadContactSizes: [], magicMouseTouching: true, settings: settings).isActive)
    #expect(!engine.update(trackpadContactSizes: [], magicMouseTouching: false, settings: settings).isActive)
}

@Test func magicMouseTapToggleChangesOnlyOnNewTouchSession() {
    var engine = MIDIHelperSustainState()
    let settings = MIDIHelperSustainSettings(
        magicMouseEnabled: true,
        magicMouseGesture: .tapToggle
    )
    #expect(engine.update(trackpadContactSizes: [], magicMouseTouching: true, settings: settings).isActive)
    #expect(engine.update(trackpadContactSizes: [], magicMouseTouching: true, settings: settings).isActive)
    #expect(engine.update(trackpadContactSizes: [], magicMouseTouching: false, settings: settings).isActive)
    #expect(!engine.update(trackpadContactSizes: [], magicMouseTouching: true, settings: settings).isActive)
}

@Test func twoSurfacesCombineWithoutPrematureRelease() {
    var engine = MIDIHelperSustainState()
    let settings = MIDIHelperSustainSettings(
        trackpadEnabled: true,
        trackpadContactThreshold: 0.5,
        magicMouseEnabled: true
    )
    let both = engine.update(
        trackpadContactSizes: [0.75],
        magicMouseTouching: true,
        settings: settings
    )
    #expect(both.trackpadActive)
    #expect(both.magicMouseActive)
    #expect(engine.update(
        trackpadContactSizes: [],
        magicMouseTouching: true,
        settings: settings
    ).isActive)
    #expect(!engine.update(
        trackpadContactSizes: [],
        magicMouseTouching: false,
        settings: settings
    ).isActive)
}

@Test func disablingMagicMouseOrResettingReleasesLatchedSustain() {
    var engine = MIDIHelperSustainState()
    let enabled = MIDIHelperSustainSettings(magicMouseEnabled: true, magicMouseGesture: .tapToggle)
    #expect(engine.update(trackpadContactSizes: [], magicMouseTouching: true, settings: enabled).isActive)

    let disabled = MIDIHelperSustainSettings(magicMouseEnabled: false)
    #expect(!engine.update(trackpadContactSizes: [], magicMouseTouching: true, settings: disabled).isActive)

    _ = engine.update(trackpadContactSizes: [], magicMouseTouching: false, settings: enabled)
    #expect(engine.update(trackpadContactSizes: [], magicMouseTouching: true, settings: enabled).isActive)
    engine.reset()
    #expect(!engine.snapshot.isActive)
}
