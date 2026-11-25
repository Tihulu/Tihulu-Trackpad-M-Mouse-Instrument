import Testing
@testable import NoSpeakerCore

@Test func helperRoutingTransitionReleasesOldTargetsOnlyWhenOwned() {
    let old = HelperRoutingSnapshot(sendToDAW:true,channel:1,bendRange:12,vibratoCC:1,expressionCC:11)
    for next in [
        HelperRoutingSnapshot(sendToDAW:true,channel:2,bendRange:12,vibratoCC:1,expressionCC:11),
        .init(sendToDAW:true,channel:1,bendRange:7,vibratoCC:1,expressionCC:11),
        .init(sendToDAW:true,channel:1,bendRange:12,vibratoCC:2,expressionCC:11),
        .init(sendToDAW:true,channel:1,bendRange:12,vibratoCC:1,expressionCC:74),
        .init(sendToDAW:false,channel:1,bendRange:12,vibratoCC:1,expressionCC:11)
    ] { #expect(old.requiresRelease(before:next,otherMappingChanged:false)) }
    #expect(!old.requiresRelease(before:old,otherMappingChanged:false))
    #expect(old.requiresRelease(before:old,otherMappingChanged:true))
    let silent = HelperRoutingSnapshot(sendToDAW:false,channel:1,bendRange:12,vibratoCC:1,expressionCC:11)
    #expect(!silent.requiresRelease(before:old,otherMappingChanged:true))
}


@Test func helperCCPolicyRejectsProtocolAndChannelModeControls() {
    let excluded = Set([0,6,32,38,64,96,97,98,99,100,101] + Array(120...127))
    for cc in -1...128 {
        #expect(HelperCCPolicy.permits(cc) == ((0...127).contains(cc) && !excluded.contains(cc)))
    }
    #expect(HelperCCPolicy.choices.count == 109)
    #expect(HelperCCPolicy.choices.contains(74))
}
@Test func helperCCPolicyRejectsActiveDuplicateOnlyAndPreservesDisabledSettings() {
    #expect(!HelperCCPolicy.permits(vibrato:true,expression:true,vibratoCC:74,expressionCC:74))
    #expect(HelperCCPolicy.permits(vibrato:true,expression:false,vibratoCC:74,expressionCC:74))
    #expect(HelperCCPolicy.permits(vibrato:false,expression:true,vibratoCC:64,expressionCC:11))
    #expect(!HelperCCPolicy.permits(vibrato:true,expression:false,vibratoCC:64,expressionCC:11))
    #expect(HelperCCPolicy.permits(vibrato:true,expression:true,vibratoCC:1,expressionCC:11))
}

@Test func helperEffectsEditsDoNotReleaseKeyboardPedal() {
    let old = HelperRoutingSnapshot(sendToDAW:true,channel:0,bendRange:12,vibratoCC:1,expressionCC:11)
    let next = HelperRoutingSnapshot(sendToDAW:true,channel:0,bendRange:2,vibratoCC:74,expressionCC:11)
    let edit = HelperMappingTransition(old:old,next:next,oldAssignments:.hybrid,nextAssignments:.hybrid,
        pedalSettingsChanged:false,surfaceChanged:false,sharingChanged:false)
    #expect(!edit.pedalChanged && edit.effectsChanged)
    let disabled = HelperMappingTransition(old:old,next:next,oldAssignments:.sustainOnly,nextAssignments:.sustainOnly,
        pedalSettingsChanged:false,surfaceChanged:false,sharingChanged:false)
    #expect(!disabled.pedalChanged && !disabled.effectsChanged)
    let channel = HelperRoutingSnapshot(sendToDAW:true,channel:2,bendRange:12,vibratoCC:1,expressionCC:11)
    let reroute = HelperMappingTransition(old:old,next:channel,oldAssignments:.hybrid,nextAssignments:.hybrid,
        pedalSettingsChanged:false,surfaceChanged:false,sharingChanged:false)
    #expect(reroute.pedalChanged && reroute.effectsChanged)
}
