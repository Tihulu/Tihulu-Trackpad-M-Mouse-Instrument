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

@Test func trackpadTouchHoldAndTapToggleWorkIndependently() {
    var engine = MIDIHelperSustainState()
    var config = MIDIHelperSustainSettings(trackpadEnabled: true, trackpadGesture: .touchHold)
    #expect(engine.update(trackpadContactSizes: [0.05], magicMouseTouching: false, settings: config).isActive)
    #expect(!engine.update(trackpadContactSizes: [], magicMouseTouching: false, settings: config).isActive)
    config.trackpadGesture = .tapToggle
    #expect(engine.update(trackpadContactSizes: [0.05], magicMouseTouching: false, settings: config).isActive)
    #expect(engine.update(trackpadContactSizes: [], magicMouseTouching: false, settings: config).isActive)
    #expect(!engine.update(trackpadContactSizes: [0.3], magicMouseTouching: false, settings: config).isActive)
}

@Test func physicalClickHoldAndToggleDoNotDependOnContactSize() {
    var engine = MIDIHelperSustainState()
    var config = MIDIHelperSustainSettings(
        trackpadEnabled: true,
        magicMouseEnabled: true,
        magicMouseGesture: .physicalClickHold,
        trackpadGesture: .physicalClickHold
    )
    #expect(!engine.update(
        trackpadContactSizes: [0.9], magicMouseTouching: true, settings: config
    ).isActive)
    #expect(engine.update(
        trackpadContactSizes: [], magicMouseTouching: false, settings: config,
        trackpadClickDown: true
    ).trackpadActive)
    #expect(engine.update(
        trackpadContactSizes: [], magicMouseTouching: false, settings: config,
        magicMouseClickDown: true
    ).magicMouseActive)
    config.trackpadGesture = .physicalClickToggle
    config.magicMouseGesture = .physicalClickToggle
    engine.reset()
    #expect(engine.update(
        trackpadContactSizes: [], magicMouseTouching: false, settings: config,
        trackpadClickDown: true, magicMouseClickDown: true
    ).isActive)
    #expect(engine.update(
        trackpadContactSizes: [], magicMouseTouching: false, settings: config,
        trackpadClickDown: false, magicMouseClickDown: false
    ).isActive)
    #expect(!engine.update(
        trackpadContactSizes: [], magicMouseTouching: false, settings: config,
        trackpadClickDown: true, magicMouseClickDown: true
    ).isActive)
}

@Test func helperAssignmentsCanSelectAnyCombination() {
    let blank = MIDIHelperAssignments(vibrato: false, pitchBend: false, expression: false)
    #expect(!blank.vibrato && !blank.pitchBend && !blank.expression)
    let hybrid = MIDIHelperAssignments.hybrid
    #expect(hybrid.vibrato && hybrid.pitchBend && hybrid.expression)
}

@Test func mouseTapThresholdRequiresFreshQualifiedOnset() {
    var state = MIDIHelperSustainState()
    let config = MIDIHelperSustainSettings(magicMouseEnabled:true,magicMouseGesture:.tapToggle,magicMouseTapThreshold:0.5)
    func sample(_ touching:Bool,_ sizes:[Double]) -> MIDIHelperSustainSnapshot {
        state.update(trackpadContactSizes:[],magicMouseTouching:touching,settings:config,magicMouseContactSizes:sizes)
    }
    #expect(!sample(true,[0.49]).isActive)
    #expect(!sample(true,[0.9]).isActive)
    #expect(!sample(false,[]).isActive)
    #expect(sample(true,[0.5]).isActive)
    #expect(sample(true,[0.1]).isActive)
    #expect(sample(true,[0.9]).isActive)
    #expect(sample(false,[]).isActive)
    #expect(!sample(true,[0.8]).isActive)
}

@Test func mouseTapThresholdRejectsMissingAndInvalidSizes() {
    for sizes: [Double] in [[],[.nan],[.infinity],[-1],[1.1]] {
        var state = MIDIHelperSustainState()
        let config = MIDIHelperSustainSettings(magicMouseEnabled:true,magicMouseGesture:.tapToggle,magicMouseTapThreshold:0.5)
        #expect(!state.update(trackpadContactSizes:[],magicMouseTouching:true,settings:config,magicMouseContactSizes:sizes).isActive)
    }
}

@Test func mouseTapThresholdDoesNotChangeTrackpadOrMouseHold() {
    var state = MIDIHelperSustainState()
    let config = MIDIHelperSustainSettings(trackpadEnabled:true,magicMouseEnabled:true,magicMouseGesture:.touchHold,magicMouseTapThreshold:0.9)
    let both = state.update(trackpadContactSizes:[0.8],magicMouseTouching:true,settings:config,magicMouseContactSizes:[0.1])
    #expect(both.trackpadActive && both.magicMouseActive)
    let remaining = state.update(trackpadContactSizes:[0.8],magicMouseTouching:false,settings:config)
    #expect(remaining.trackpadActive && !remaining.magicMouseActive)
}

@Test func lostClickMonitorClearsOnlyClickDerivedSustain() {
    var engine = MIDIHelperSustainState()
    let config = MIDIHelperSustainSettings(trackpadEnabled:true,magicMouseEnabled:true,
        magicMouseGesture:.tapToggle,trackpadGesture:.physicalClickToggle)
    let initial = engine.update(trackpadContactSizes:[0.6],magicMouseTouching:true,settings:config,trackpadClickDown:true)
    #expect(initial.trackpadActive && initial.magicMouseActive)
    engine.invalidatePhysicalClicks(settings:config)
    #expect(!engine.snapshot.trackpadActive && engine.snapshot.magicMouseActive)
    let next = engine.update(trackpadContactSizes:[0.6],magicMouseTouching:true,settings:config)
    #expect(!next.trackpadActive && next.magicMouseActive)
}

@Test func lostClickMonitorReleasesMouseToggleAndPressure() {
    var engine = MIDIHelperSustainState()
    let config = MIDIHelperSustainSettings(trackpadEnabled:true,magicMouseEnabled:true,
        magicMouseGesture:.physicalClickToggle,trackpadSensor:.clickPressure)
    #expect(config.needsPhysicalClicks)
    let initial = engine.update(trackpadContactSizes:[],magicMouseTouching:false,settings:config,
        trackpadClickDown:true,magicMouseClickDown:true,trackpadClickPressure:0.9)
    #expect(initial.trackpadActive && initial.magicMouseActive)
    engine.invalidatePhysicalClicks(settings:config)
    #expect(!engine.snapshot.isActive)
    #expect(!engine.update(trackpadContactSizes:[],magicMouseTouching:false,settings:config).isActive)
}

@Test func malformedSustainInputCannotArmThresholdOrTouchHold() {
    for threshold in [Double.nan,.infinity,-0.1,1.1] {
        var engine = MIDIHelperSustainState()
        let config = MIDIHelperSustainSettings(trackpadEnabled:true,trackpadContactThreshold:threshold)
        #expect(!engine.update(trackpadContactSizes:[0.9],magicMouseTouching:false,settings:config).isActive)
    }
    var engine = MIDIHelperSustainState()
    let config = MIDIHelperSustainSettings(trackpadEnabled:true,trackpadGesture:.touchHold)
    #expect(!engine.update(trackpadContactSizes:[.nan,-1,2],magicMouseTouching:false,settings:config).isActive)
}

@Test func clickAttributionRejectsAmbiguousStaleAndOldRevision() {
    let one:Set<String> = ["trackpad"]
    #expect(PhysicalClickAttribution.resolve(one,snapshotRevision:2,currentRevision:2,receivedAt:1,now:1.1) == "trackpad")
    #expect(PhysicalClickAttribution.resolve(one,snapshotRevision:1,currentRevision:2,receivedAt:1,now:1.1) == nil)
    #expect(PhysicalClickAttribution.resolve(one,snapshotRevision:2,currentRevision:2,receivedAt:1,now:1.5) == nil)
    #expect(PhysicalClickAttribution.resolve(one,snapshotRevision:2,currentRevision:2,receivedAt:1,now:0.9) == nil)
    #expect(PhysicalClickAttribution.resolve(Set(["trackpad","mouse"]),snapshotRevision:2,currentRevision:2,receivedAt:1,now:1.1) == nil)
    #expect(PhysicalClickAttribution.resolve(Set<String>(),snapshotRevision:2,currentRevision:2,receivedAt:1,now:1.1) == nil)
}

@Test func helperPedalSurfacesDoNotDriveGainOrBendByDefault() {
    let config = MIDIHelperSustainSettings(trackpadEnabled:true,magicMouseEnabled:false)
    #expect(!HelperPerformancePolicy.permitsEffects(isTrackpad:true,settings:config,sharePedalSurface:false))
    #expect(HelperPerformancePolicy.permitsEffects(isTrackpad:false,settings:config,sharePedalSurface:false))
    #expect(HelperPerformancePolicy.permitsEffects(isTrackpad:true,settings:config,sharePedalSurface:true))
    #expect(!HelperPerformancePolicy.validContact(x:.nan,y:0.5,size:0.6))
    #expect(!HelperPerformancePolicy.validContact(x:0.5,y:0.5,size:2))
}
@Test func helperOrdinaryLiftDoesNotForceGainTo127OrZero() {
    let volume = SensorDestination(.controlChange,number:7)
    let expression = SensorDestination(.controlChange,number:11)
    let wah = SensorDestination(.controlChange,number:74)
    let bend = SensorDestination(.pitchBend)
    var owners = LegacyContinuousOwners()
    let values:[SensorDestination:LegacyContinuousOwners.Value] = [
        volume:HelperPerformancePolicy.gainValue(55,cc:7),expression:HelperPerformancePolicy.gainValue(42,cc:11),
        wah:.init(80,neutral:0),bend:.init(10000,neutral:8192,bendRange:12)]
    _ = owners.replace(.helper,values:values)
    let release = owners.release(.helper)
    #expect(Set(release.map(\.target)) == [wah,bend])
    #expect(owners.values(for:.helper).isEmpty)
    #expect(owners.release(.helper).isEmpty)
}
@Test func keyboardSustainOnlyProductionPlannerAndWireEdges() throws {
    var pedal = LegacySustainOwners(), owners = LegacyContinuousOwners()
    let target = SensorDestination(.sustain,channel:2)
    for active in [false,true,true,false,false] {
        let values = try #require(HelperPerformancePolicy.controls(x:0.99,y:0.99,size:0.99,assignments:.sustainOnly,
            channel:2,bendRange:12,vibratoCC:7,expressionCC:11))
        #expect(values.isEmpty)
        #expect(owners.replace(.helper,values:values).isEmpty)
        let messages = pedal.replace(.helper,channels:active ? [2] : [])
        #expect(messages.allSatisfy { $0.destination == target && [0,127].contains($0.value) })
    }
    #expect(pedal.releaseAll().isEmpty)
}
@Test func helperBendDoesNotConfigureKeyboardRangeUnlessExplicit() throws {
    let a = MIDIHelperAssignments(vibrato:false,pitchBend:true,expression:false)
    let target = SensorDestination(.pitchBend,channel:2)
    let safe = try #require(HelperPerformancePolicy.controls(x:1,y:0.5,size:0.6,assignments:a,channel:2,bendRange:12,vibratoCC:1,expressionCC:11))
    var owners = LegacyContinuousOwners()
    #expect(owners.replace(.helper,values:safe) == [.init(target,value:16383)])
    #expect(owners.release(.helper) == [.init(target,value:8192)])
    let explicit = try #require(HelperPerformancePolicy.controls(x:1,y:0.5,size:0.6,assignments:a,channel:2,bendRange:12,vibratoCC:1,expressionCC:11,configureReceiverBendRange:true))
    #expect(owners.replace(.helper,values:explicit) == [.init(target,value:16383,bendRange:12)])
}

@Test func helperMappingChangeRequiresIdleFrameBeforeNewOnset() {
    var gate = HelperRearmGate()
    let allowed1 = gate.permits(touching:true,clicking:false)
    #expect(allowed1)
    gate.invalidate()
    let allowed2 = gate.permits(touching:true,clicking:false)
    #expect(!allowed2)
    let allowed3 = gate.permits(touching:false,clicking:true)
    #expect(!allowed3)
    #expect(gate.waiting)
    let allowed4 = gate.permits(touching:false,clicking:false)
    #expect(!allowed4)
    #expect(!gate.waiting)
    let allowed5 = gate.permits(touching:true,clicking:false)
    #expect(allowed5)
    gate.invalidate()
    gate.reset()
    let allowed6 = gate.permits(touching:true,clicking:true)
    #expect(allowed6)
}
