import Testing
@testable import NoSpeakerCore

@Test func touchBarOldGesturesCannotCrossStopOrProfileReplacement() {
    var epoch = TouchBarGestureEpoch()
    let old = epoch.revision
    #expect(epoch.accepts(old))
    #expect(epoch.permitsSample(captured:old))
    epoch.invalidate()
    #expect(!epoch.accepts(old))
    #expect(!epoch.permitsSample(captured:old))
    let fresh = epoch.revision
    #expect(epoch.accepts(fresh))
    #expect(epoch.permitsSample(captured:fresh))
    epoch.invalidate()
    #expect(!epoch.accepts(fresh))
    #expect(!epoch.accepts(old))
    #expect(epoch.permitsSample(captured:nil))
}

@Test func touchBarIndependentGestureEpochsDoNotRevokeEachOther() {
    var profile = TouchBarGestureEpoch()
    var gesture = TouchBarGestureEpoch()
    let oldProfile = profile.revision
    let oldGesture = gesture.revision
    gesture.invalidate()
    #expect(profile.accepts(oldProfile))
    #expect(!gesture.accepts(oldGesture))
    let newGesture = gesture.revision
    profile.invalidate()
    #expect(!profile.accepts(oldProfile))
    #expect(gesture.accepts(newGesture))
}

@Test func touchBarOldOptionalDebtPreservesLegacyGesture() {
    for sendsHaptics in [false,true] {
        for armed in [false,true] {
            var epoch = TouchBarGestureEpoch()
            let captured = epoch.revision
            // The caller retries old optional debt in all four cases.
            // Only the active optional scope may cancel its tap timers.
            let cancelTimers = epoch.invalidateOptionalOutput(sendsHaptics:sendsHaptics,armed:armed)
            #expect(cancelTimers == (sendsHaptics || armed))
            #expect(epoch.accepts(captured) == !cancelTimers)
        }
    }
}
