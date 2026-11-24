import Testing
@testable import NoSpeakerCore

@Test func controllerDebtPreservesExplicitNeutralAndRetriesFailedNeutral() {
    var debt = LegacyControllerReleaseDebt()
    debt.record(.init(0xb2,74,60),neutral:127,succeeded:true)
    debt.record(.init(0xb2,74,127),neutral:127,succeeded:false)
    #expect(debt.pending == [.init(0xb2,74,127)])
    debt.record(.init(0xb2,74,127),neutral:127,succeeded:true)
    #expect(debt.isEmpty)
}
@Test func controllerDebtTracksBendPressureAndPartialRangeIndependently() {
    var debt = LegacyControllerReleaseDebt()
    debt.beginRange(channel:3)
    debt.record(.init(0xe3,1,80),neutral:8192,succeeded:false)
    debt.record(.init(0xd3,90,0),neutral:0,succeeded:true)
    debt.record(.init(0xb4,11,30),neutral:127,succeeded:true)
    #expect(debt.pendingRanges == [3])
    #expect(debt.pending == [.init(0xb4,11,127),.init(0xd3,0,0),.init(0xe3,0,64)])
    debt.completeRange(channel:3)
    debt.record(.init(0xe3,0,64),neutral:8192,succeeded:true)
    debt.record(.init(0xd3,0,0),neutral:0,succeeded:true)
    debt.record(.init(0xb4,11,127),neutral:127,succeeded:true)
    #expect(debt.isEmpty)
}
@Test func continuousUpdateCarriesExplicitNeutralAcrossOwnerHandoff() {
    var owners = LegacyContinuousOwners()
    let cc = SensorDestination(.controlChange,channel:0,number:74)
    _ = owners.set(.touchBar,target:cc,value:.init(60,neutral:0))
    let handoff = owners.set(.helper,target:cc,value:.init(60,neutral:127))
    #expect(handoff == [.init(cc,value:60,neutral:127)])
    #expect(owners.release(.helper) == [.init(cc,value:60,neutral:0)])
    #expect(owners.releaseAll() == [.init(cc,value:0)])
}

@Test func legacyRecoverySendAndReplacementPolicyExhaustive() {
    for enabled in [false,true] {
        for faulted in [false,true] {
            for cleaning in [false,true] {
                #expect(LegacyRecoveryPolicy.permitsSend(enabled:enabled,faulted:faulted,cleaning:cleaning) ==
                    (cleaning || (enabled && !faulted)))
            }
        }
    }
    for gates in [false,true] {
        for controllers in [false,true] {
            for unknown in [false,true] {
                #expect(LegacyRecoveryPolicy.permitsReplacement(gatesPending:gates,controllersPending:controllers,unknownFailure:unknown) ==
                    (!gates && !controllers && !unknown))
            }
        }
    }
}


@Test func legacyFullStopUsesActualAttemptDebtNotDepartingFallback() {
    let cc = SensorDestination(.controlChange,channel:0,number:74)
    let neverSent = SensorDestination(.controlChange,channel:1,number:11)
    var owners = LegacyContinuousOwners()
    var debt = LegacyControllerReleaseDebt()
    let low = owners.set(.helper,target:cc,value:.init(30,neutral:0))
    #expect(low.count == 1)
    debt.record(.init(0xb0,74,30),neutral:0,succeeded:true)
    let high = owners.set(.touch,target:cc,value:.init(90,neutral:0))
    #expect(high.count == 1)
    debt.record(.init(0xb0,74,90),neutral:0,succeeded:true)
    // A normal handoff would restore 30, inappropriate for a global stop.
    var scoped = owners
    #expect(scoped.release(.touch) == [.init(cc,value:30)])
    // Simulate a logical update suppressed following a submission fault.
    _ = owners.set(.touch,target:neverSent,value:.init(80,neutral:127))
    owners = LegacyContinuousOwners()
    #expect(owners.values(for:.touch).isEmpty)
    #expect(debt.pending == [.init(0xb0,74,0)])
    debt.record(.init(0xb0,74,0),neutral:0,succeeded:false)
    #expect(debt.pending == [.init(0xb0,74,0)])
    debt.record(.init(0xb0,74,0),neutral:0,succeeded:true)
    #expect(debt.isEmpty)
}

@Test func stoppedSustainReleaseDoesNotAuthorizeBridgeStart() {
    #expect(!LegacyRecoveryPolicy.permitsSustainEvent(running:false,pressed:false))
    #expect(LegacyRecoveryPolicy.permitsSustainEvent(running:false,pressed:true))
    #expect(LegacyRecoveryPolicy.permitsSustainEvent(running:true,pressed:false))
    #expect(LegacyRecoveryPolicy.permitsSustainEvent(running:true,pressed:true))
}

@Test func stoppedTouchBarNeutralizationDoesNotAuthorizeBridgeStart() {
    for running in [false,true] {
        for releaseOnly in [false,true] {
            let permitted = LegacyRecoveryPolicy.permitsControlEvent(running:running,releaseOnly:releaseOnly)
            #expect(permitted == (running || !releaseOnly))
        }
    }
}
