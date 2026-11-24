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
