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

@Test func helperRearmCannotUseCachedClickCallbackAsIdleEvidence() {
    var gate = HelperRearmGate()
    gate.invalidate()
    let cached = gate.permits(touching:false,clicking:false,freshFrame:false)
    #expect(!cached && gate.waiting)
    let real = gate.permits(touching:false,clicking:false,freshFrame:true)
    #expect(!real && !gate.waiting)
    let next = gate.permits(touching:true,clicking:false,freshFrame:true)
    #expect(next)
}

@Test func clickAttributionRejectsContactsThatArrivedAfterTheClick() {
    let one = Set(["trackpad"])
    #expect(PhysicalClickAttribution.resolve(one,snapshotRevision:2,currentRevision:2,receivedAt:1.02,now:1.04,clickReceipt:1.01) == nil)
    #expect(PhysicalClickAttribution.resolve(one,snapshotRevision:2,currentRevision:2,receivedAt:1.01,now:1.04,clickReceipt:1.02) == "trackpad")
    #expect(PhysicalClickAttribution.resolve(one,snapshotRevision:2,currentRevision:2,receivedAt:1.01,now:1.04,clickReceipt:1.05) == nil)
    #expect(PhysicalClickAttribution.resolve(one,snapshotRevision:2,currentRevision:2,receivedAt:1.01,now:1.04,clickReceipt:.nan) == nil)
    #expect(PhysicalClickAttribution.resolve(one,snapshotRevision:2,currentRevision:2,receivedAt:1.01,now:1.04,clickReceipt:-1) == nil)
}

@Test func physicalClickSessionFenceRejectsPriorSessionsAndUnselectedSurfaces() {
    var helper = PhysicalClickSessionFence(), touch = PhysicalClickSessionFence()
    #expect(!helper.permits(receipt:1,now:2,selected:true))
    helper.begin(now:1)
    touch.begin(now:2)
    #expect(helper.permits(receipt:1.5,now:3,selected:true))
    #expect(!touch.permits(receipt:1.5,now:3,selected:true))
    #expect(!helper.permits(receipt:1.5,now:3,selected:false))
    #expect(!helper.permits(receipt:4,now:3,selected:true))
    #expect(!helper.permits(receipt:.nan,now:3,selected:true))
    #expect(helper.permits(receipt:1.5,now:100,selected:true))
    helper.begin(now:3)
    #expect(!helper.permits(receipt:1.5,now:3.1,selected:true))
    #expect(touch.permits(receipt:2.1,now:3.1,selected:true))
    helper.end()
    #expect(!helper.permits(receipt:3.2,now:3.3,selected:true))
    touch.begin(now:.nan)
    #expect(!touch.permits(receipt:3.2,now:3.3,selected:true))
}

@Test func deselectedSurfaceCannotRetainToggleSustain() {
    let settings = MIDIHelperSustainSettings(trackpadEnabled:true,magicMouseEnabled:true,
        magicMouseGesture:.physicalClickToggle,trackpadGesture:.physicalClickToggle)
    var state = MIDIHelperSustainState()
    let both = state.update(trackpadContactSizes:[],magicMouseTouching:false,settings:settings,
        trackpadClickDown:true,magicMouseClickDown:true)
    #expect(both.trackpadActive && both.magicMouseActive)
    let mouseOnly = settings.restricted(trackpad:false,magicMouse:true)
    let restricted = state.update(trackpadContactSizes:[],magicMouseTouching:false,settings:mouseOnly)
    #expect(!restricted.trackpadActive && restricted.magicMouseActive)
    let neither = state.update(trackpadContactSizes:[],magicMouseTouching:false,
        settings:settings.restricted(trackpad:false,magicMouse:false))
    #expect(!neither.isActive)
    let restored = state.update(trackpadContactSizes:[],magicMouseTouching:false,settings:settings)
    #expect(!restored.isActive && settings.trackpadEnabled && settings.magicMouseEnabled)
}

@Test func touchSurfaceRearmRejectsCachedAndHeldTapWithoutBlockingHelper() {
    var touch = HelperRearmGate(), helper = HelperRearmGate()
    var pedal = MIDIHelperSustainState()
    let settings = MIDIHelperSustainSettings(magicMouseEnabled:true,magicMouseGesture:.tapToggle)
    touch.invalidate()
    pedal.reset()
    // A queued click callback with an empty cache is not a neutral frame.
    let cached = touch.permits(touching:false,clicking:false,freshFrame:false)
    #expect(!cached && touch.waiting)
    let held = touch.permits(touching:true,clicking:false,freshFrame:true)
    #expect(!held && touch.waiting)
    let otherConsumer = helper.permits(touching:true,clicking:false,freshFrame:true)
    #expect(otherConsumer && !helper.waiting)
    #expect(!pedal.snapshot.isActive)
    let neutral = touch.permits(touching:false,clicking:false,freshFrame:true)
    #expect(!neutral && !touch.waiting)
    let onset = touch.permits(touching:true,clicking:false,freshFrame:true)
    #expect(onset)
    if onset {
        let snapshot = pedal.update(trackpadContactSizes:[],magicMouseTouching:true,settings:settings)
        #expect(snapshot.magicMouseActive)
    }
}

@Test func physicalClickRearmDoesNotAdmitHeldClickOrConsumeOtherConsumerGate() {
    var touch = HelperRearmGate(), helper = HelperRearmGate()
    touch.invalidate()
    helper.invalidate()
    let down = touch.permits(touching:false,clicking:true,freshFrame:true)
    #expect(!down && touch.waiting)
    let upCallback = touch.permits(touching:false,clicking:false,freshFrame:false)
    #expect(!upCallback && touch.waiting)
    let idle = touch.permits(touching:false,clicking:false,freshFrame:true)
    #expect(!idle && !touch.waiting && helper.waiting)
    let next = touch.permits(touching:true,clicking:true,freshFrame:false)
    #expect(next && helper.waiting)
    touch.reset()
    #expect(!touch.waiting && helper.waiting)
}
 
@Test func sharedTouchPedalBeforeReleaseReservesExistingMPEMember() {
    var owners = LegacySustainOwners()
    var pool = LegacyMPEChannelPool()
    let before = LegacyTouchSustainTargets.resolve(active:true,previous:[],current:[1],
        baseChannel:0,allowIdleFallback:false)
    let on = owners.replace(.touch,channels:before)
    #expect(on == [.init(.init(.sustain,channel:1),value:127)])
    let transition1 = pool.retire(channel:1,sustained:owners.active.contains(1),fretless:true)
    #expect(!transition1)
    #expect(pool.reserved == [1])
    #expect(pool.next(occupied:[],sustained:owners.active) == 2)
    let after = LegacyTouchSustainTargets.resolve(active:true,previous:owners.channels(for:.touch),
        current:[2],baseChannel:0,allowIdleFallback:true)
    let transition2 = owners.replace(.touch,channels:after)
    #expect(transition2 == [.init(.init(.sustain,channel:2),value:127)])
    let transition3 = owners.replace(.touch,channels:[])
    #expect(transition3 == [
        .init(.init(.sustain,channel:1),value:0),.init(.init(.sustain,channel:2),value:0)])
    let transition4 = pool.pedalChanged(sustained:owners.active)
    #expect(transition4 == [1])
    #expect(pool.reserved.isEmpty)
}

@Test func sharedTouchPedalDoesNotReserveIdleMemberBeforeAllocation() {
    var owners = LegacySustainOwners()
    let pool = LegacyMPEChannelPool()
    let before = LegacyTouchSustainTargets.resolve(active:true,previous:[],current:[],
        baseChannel:1,allowIdleFallback:false)
    let transition5 = owners.replace(.touch,channels:before)
    #expect(transition5.isEmpty)
    #expect(pool.next(occupied:[],sustained:owners.active) == 1)
    let after = LegacyTouchSustainTargets.resolve(active:true,previous:[],current:[1],
        baseChannel:1,allowIdleFallback:true)
    #expect(after == [1])
    #expect(LegacyTouchSustainTargets.resolve(active:true,previous:[],current:[],
        baseChannel:3,allowIdleFallback:true) == [3])
    #expect(LegacyTouchSustainTargets.resolve(active:false,previous:[1],current:[2],
        baseChannel:0,allowIdleFallback:true).isEmpty)
}

@Test func sharedTouchPedalOffKeepsIndependentHelperOwner() {
    var owners = LegacySustainOwners()
    _ = owners.replace(.helper,channels:[2])
    _ = owners.replace(.touch,channels:[1,2])
    let off = LegacyTouchSustainTargets.resolve(active:false,previous:[1,2],current:[1],
        baseChannel:0,allowIdleFallback:false)
    let transition6 = owners.replace(.touch,channels:off)
    #expect(transition6 == [.init(.init(.sustain,channel:1),value:0)])
    #expect(owners.active == [2])
}

@Test func sameFrameSustainHandoffIsSilentInBothDirections() {
    var owners = LegacySustainOwners()
    _ = owners.replace(.touch,channels:[2])
    let transition7 = owners.replaceFrame([.touch:[],.helper:[2]])
    #expect(transition7.isEmpty)
    #expect(owners.channels(for:.touch).isEmpty && owners.channels(for:.helper) == [2])
    let transition8 = owners.replaceFrame([.helper:[],.touch:[2]])
    #expect(transition8.isEmpty)
    #expect(owners.active == [2])
    let transition9 = owners.replaceFrame([.touch:[],.helper:[]])
    #expect(transition9 == [.init(.init(.sustain,channel:2),value:0)])
}

@Test func frameSustainUpdatesDoNotReleaseOmittedOwners() {
    var owners = LegacySustainOwners()
    _ = owners.replace(.touchBar,channels:[1,4])
    _ = owners.replace(.helper,channels:[2])
    _ = owners.replace(.touch,channels:[1,3])
    let delta = owners.replaceFrame([.touch:[2,5],.helper:[3]])
    #expect(delta == [.init(.init(.sustain,channel:5),value:127)])
    #expect(owners.active == [1,2,3,4,5])
    #expect(owners.channels(for:.touchBar) == [1,4])
    let transition10 = owners.replaceFrame([:])
    #expect(transition10.isEmpty)
    let transition11 = owners.replaceFrame([.touch:[],.helper:[]])
    #expect(transition11 == [
        .init(.init(.sustain,channel:2),value:0),
        .init(.init(.sustain,channel:3),value:0),
        .init(.init(.sustain,channel:5),value:0)])
    #expect(owners.active == [1,4])
}

@Test func frameHandoffPreservesRetiredMPEMemberUntilLastOwnerReleases() {
    var owners = LegacySustainOwners()
    var pool = LegacyMPEChannelPool()
    _ = owners.replace(.helper,channels:[1])
    _ = pool.retire(channel:1,sustained:true,fretless:true)
    let transition12 = owners.replaceFrame([.helper:[],.touch:[1]])
    #expect(transition12.isEmpty)
    let transition13 = pool.pedalChanged(sustained:owners.active)
    #expect(transition13.isEmpty)
    #expect(pool.reserved == [1])
    _ = owners.replaceFrame([.touch:[]])
    let transition14 = pool.pedalChanged(sustained:owners.active)
    #expect(transition14 == [1])
    #expect(pool.reserved.isEmpty)
}

@Test func routedStandardPedalUsesActualFixedDrumAndMelodyChannels() {
    let drums = LegacyTouchSustainTargets.fixedChannels(baseChannel:2,hasMelody:false,hasDrums:true,isMPE:false)
    #expect(drums == [9])
    let mixed = LegacyTouchSustainTargets.fixedChannels(baseChannel:9,hasMelody:true,hasDrums:true,isMPE:false)
    #expect(mixed == [0,9])
    let melody = LegacyTouchSustainTargets.fixedChannels(baseChannel:9,hasMelody:true,hasDrums:false,isMPE:false)
    #expect(melody == [9])
    let none = LegacyTouchSustainTargets.fixedChannels(baseChannel:4,hasMelody:false,hasDrums:false,isMPE:false)
    #expect(none.isEmpty)
}

@Test func routedMPEIdlePedalDoesNotClaimMasterOrAnyUnusedMember() {
    let pool = LegacyMPEChannelPool()
    for base in 0...15 {
        let fixed = LegacyTouchSustainTargets.fixedChannels(baseChannel:base,hasMelody:true,hasDrums:false,isMPE:true)
        let channels = LegacyTouchSustainTargets.routed(active:true,previous:[],current:[],fixed:fixed)
        #expect(channels.isEmpty)
        #expect(pool.next(occupied:[],sustained:channels) == 1)
    }
    let drums = LegacyTouchSustainTargets.fixedChannels(baseChannel:1,hasMelody:true,hasDrums:true,isMPE:true)
    #expect(drums == [9])
}

@Test func routedMPEPedalCanExtendAllMembersWithoutLosingAChannelToIdleFallback() {
    var pool = LegacyMPEChannelPool()
    var owners = LegacySustainOwners()
    let fixed = LegacyTouchSustainTargets.fixedChannels(baseChannel:1,hasMelody:true,hasDrums:false,isMPE:true)
    let idle = LegacyTouchSustainTargets.routed(active:true,previous:[],current:[],fixed:fixed)
    _ = owners.replace(.touch,channels:idle)
    var allocated: Set<Int> = []
    for expected in (1...15).filter({ $0 != 9 }) {
        let channel = pool.next(occupied:allocated,sustained:owners.active)
        #expect(channel == expected)
        guard let channel else { return }
        let on = owners.replace(.touch,channels:owners.channels(for:.touch).union([channel]))
        #expect(on == [.init(.init(.sustain,channel:channel),value:127)])
        allocated.insert(channel)
    }
    #expect(allocated.count == 14)
    #expect(pool.next(occupied:allocated,sustained:owners.active) == nil)
    for channel in allocated {
        _ = pool.retire(channel:channel,sustained:owners.active.contains(channel),fretless:true)
    }
    #expect(pool.reserved == allocated)
    let off = owners.replace(.touch,channels:LegacyTouchSustainTargets.routed(active:false,previous:allocated,current:[],fixed:fixed))
    #expect(off.count == 14)
    let released = pool.pedalChanged(sustained:owners.active)
    #expect(Set(released) == allocated)
    #expect(pool.next(occupied:[],sustained:owners.active) == 1)
}

@Test func routedStandardHandoffKeepsPedalOnEvenWithoutAnActiveNote() {
    var owners = LegacySustainOwners()
    _ = owners.replace(.helper,channels:[3])
    let fixed = LegacyTouchSustainTargets.fixedChannels(baseChannel:3,hasMelody:true,hasDrums:false,isMPE:false)
    let targets = LegacyTouchSustainTargets.routed(active:true,previous:[],current:[],fixed:fixed)
    let changes = owners.replaceFrame([.helper:[],.touch:targets])
    #expect(changes.isEmpty)
    #expect(owners.active == [3])
}

@Test func routedSustainRetainsOnlyValidPreviouslyOwnedAndActualChannels() {
    let targets = LegacyTouchSustainTargets.routed(active:true,previous:[-1,1,16],current:[2,20],fixed:[9])
    #expect(targets == [1,2,9])
    #expect(LegacyTouchSustainTargets.routed(active:false,previous:targets,current:[2],fixed:[9]).isEmpty)
}

@Test func clickOnlyUpdatesCannotReplayOrInventContactTapEdges() {
    var engine = MIDIHelperSustainState()
    let settings = MIDIHelperSustainSettings(trackpadEnabled:true,magicMouseEnabled:true,
        magicMouseGesture:.tapToggle,trackpadGesture:.tapToggle)
    let stale = engine.update(trackpadContactSizes:[0.9],magicMouseTouching:true,
        settings:settings,magicMouseContactSizes:[0.9],freshContacts:false)
    #expect(!stale.isActive)
    let onset = engine.update(trackpadContactSizes:[0.9],magicMouseTouching:true,settings:settings)
    #expect(onset.trackpadActive && onset.magicMouseActive)
    let missing = engine.update(trackpadContactSizes:[],magicMouseTouching:false,
        settings:settings,trackpadClickDown:true,freshContacts:false)
    #expect(missing == onset)
    let held = engine.update(trackpadContactSizes:[0.8],magicMouseTouching:true,settings:settings)
    #expect(held == onset)
    _ = engine.update(trackpadContactSizes:[],magicMouseTouching:false,settings:settings)
    let newTap = engine.update(trackpadContactSizes:[0.8],magicMouseTouching:true,settings:settings)
    #expect(!newTap.isActive)
}

@Test func clickOnlyUpdatesPreserveContactSizeHysteresisAndTouchHold() {
    var engine = MIDIHelperSustainState()
    let settings = MIDIHelperSustainSettings(trackpadEnabled:true,trackpadContactThreshold:0.55,
        magicMouseEnabled:true,magicMouseGesture:.touchHold)
    let active = engine.update(trackpadContactSizes:[0.8],magicMouseTouching:true,settings:settings)
    #expect(active.trackpadActive && active.magicMouseActive)
    let callback = engine.update(trackpadContactSizes:[0.01],magicMouseTouching:false,
        settings:settings,freshContacts:false)
    #expect(callback == active)
    let hysteresis = engine.update(trackpadContactSizes:[0.5],magicMouseTouching:true,settings:settings)
    #expect(hysteresis == active)
    let lift = engine.update(trackpadContactSizes:[],magicMouseTouching:false,settings:settings)
    #expect(!lift.isActive)
}

@Test func clickPressureRemainsLiveWhileIndependentContactHoldIsPreserved() {
    var engine = MIDIHelperSustainState()
    let settings = MIDIHelperSustainSettings(trackpadEnabled:true,trackpadContactThreshold:0.55,
        magicMouseEnabled:true,magicMouseGesture:.touchHold,trackpadSensor:.clickPressure)
    let contact = engine.update(trackpadContactSizes:[],magicMouseTouching:true,settings:settings)
    #expect(!contact.trackpadActive && contact.magicMouseActive)
    let press = engine.update(trackpadContactSizes:[],magicMouseTouching:false,settings:settings,
        trackpadClickDown:true,trackpadClickPressure:0.8,freshContacts:false)
    #expect(press.trackpadActive && press.magicMouseActive)
    engine.invalidatePhysicalClicks(settings:settings)
    let recovered = engine.update(trackpadContactSizes:[],magicMouseTouching:false,
        settings:settings,freshContacts:false)
    #expect(!recovered.trackpadActive && recovered.magicMouseActive)
    let lift = engine.update(trackpadContactSizes:[],magicMouseTouching:false,settings:settings)
    #expect(!lift.isActive)
}

@Test func clickOnlyModeChangeCannotCarryOverPriorContactResult() {
    var engine = MIDIHelperSustainState()
    var settings = MIDIHelperSustainSettings(trackpadEnabled:true,magicMouseEnabled:true,
        magicMouseGesture:.touchHold,trackpadGesture:.touchHold)
    let active = engine.update(trackpadContactSizes:[0.9],magicMouseTouching:true,settings:settings)
    #expect(active.isActive)
    settings.trackpadGesture = .tapToggle
    settings.magicMouseGesture = .tapToggle
    let changed = engine.update(trackpadContactSizes:[0.9],magicMouseTouching:true,
        settings:settings,freshContacts:false)
    #expect(!changed.isActive)
    let held = engine.update(trackpadContactSizes:[0.9],magicMouseTouching:true,settings:settings)
    #expect(!held.isActive)
    _ = engine.update(trackpadContactSizes:[],magicMouseTouching:false,settings:settings)
    let next = engine.update(trackpadContactSizes:[0.9],magicMouseTouching:true,settings:settings)
    #expect(next.trackpadActive && next.magicMouseActive)
}

@Test func clickAttributionRecoveryRetiresEvenFreshQueuedContactSnapshots() {
    let one:Set<String>=["trackpad"]
    #expect(PhysicalClickAttribution.resolve(one,snapshotRevision:2,currentRevision:2,
        receivedAt:1.01,now:1.10,clickReceipt:1.09,notBefore:1.05)==nil)
    #expect(PhysicalClickAttribution.resolve(one,snapshotRevision:2,currentRevision:2,
        receivedAt:1.06,now:1.10,clickReceipt:1.04,notBefore:1.05)==nil)
    #expect(PhysicalClickAttribution.resolve(one,snapshotRevision:2,currentRevision:2,
        receivedAt:1.06,now:1.10,notBefore:1.05)==nil)
    #expect(PhysicalClickAttribution.resolve(one,snapshotRevision:2,currentRevision:2,
        receivedAt:1.06,now:1.10,clickReceipt:1.09,notBefore:1.05)=="trackpad")
    #expect(PhysicalClickAttribution.resolve(one,snapshotRevision:2,currentRevision:2,
        receivedAt:1.06,now:1.10,clickReceipt:1.09,notBefore:.nan)==nil)
}

@Test func clickRecoveryReleasesClickPedalWithoutPulsingIndependentTouchPedal() {
    var engine=MIDIHelperSustainState()
    var owners=LegacySustainOwners()
    let config=MIDIHelperSustainSettings(trackpadEnabled:true,magicMouseEnabled:true,
        magicMouseGesture:.touchHold,trackpadGesture:.physicalClickToggle)
    let initial=engine.update(trackpadContactSizes:[0.8],magicMouseTouching:true,settings:config,trackpadClickDown:true)
    #expect(initial.trackpadActive && initial.magicMouseActive)
    let on=owners.replaceFrame([.touch:[2],.helper:[2]])
    #expect(on.map(\.value)==[127])
    engine.invalidatePhysicalClicks(settings:config)
    #expect(!engine.snapshot.trackpadActive && engine.snapshot.magicMouseActive)
    let handoff=owners.replaceFrame([.touch:[],.helper:engine.snapshot.magicMouseActive ? [2] : []])
    #expect(handoff.isEmpty && owners.active==[2])
    let idle=engine.update(trackpadContactSizes:[],magicMouseTouching:false,settings:config)
    let off=owners.replace(.helper,channels:idle.isActive ? [2] : [])
    #expect(off.map(\.value)==[0] && owners.active.isEmpty)
}

@Test func invalidLivePedalThresholdReleasesEvenWithoutFreshContacts() {
    for bad in [Double.nan,.infinity,-0.1,1.1] {
        var state=MIDIHelperSustainState()
        var config=MIDIHelperSustainSettings(trackpadEnabled:true,magicMouseEnabled:true,
            magicMouseGesture:.tapToggle,magicMouseTapThreshold:0.5)
        let initial=state.update(trackpadContactSizes:[0.8],magicMouseTouching:true,settings:config,
            magicMouseContactSizes:[0.8])
        #expect(initial.trackpadActive && initial.magicMouseActive)
        config.trackpadContactThreshold=bad
        let released=state.update(trackpadContactSizes:[],magicMouseTouching:false,settings:config,freshContacts:false)
        #expect(!released.trackpadActive && released.magicMouseActive)
        config.magicMouseTapThreshold=bad
        let bothReleased=state.update(trackpadContactSizes:[],magicMouseTouching:false,settings:config,freshContacts:false)
        #expect(!bothReleased.isActive)
        config.magicMouseTapThreshold=0.5
        let held=state.update(trackpadContactSizes:[],magicMouseTouching:true,settings:config,magicMouseContactSizes:[0.9])
        #expect(!held.isActive)
        _=state.update(trackpadContactSizes:[],magicMouseTouching:false,settings:config)
        let next=state.update(trackpadContactSizes:[],magicMouseTouching:true,settings:config,magicMouseContactSizes:[0.9])
        #expect(next.magicMouseActive && !next.trackpadActive)
    }
}
