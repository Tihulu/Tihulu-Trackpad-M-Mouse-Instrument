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
