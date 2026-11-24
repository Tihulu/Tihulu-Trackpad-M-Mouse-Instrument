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
