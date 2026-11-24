import Testing
@testable import NoSpeakerCore

@Test func renderedOutputPolicyRejectsConflictingLegacyLiveProducers() {
    for mask in 0..<32 {
        let policy = RenderedOutputPolicy(rendered:mask&1 != 0,touch:mask&2 != 0,
            bridge:mask&4 != 0,helper:mask&8 != 0,hinge:mask&16 != 0)
        #expect(policy.permitsRenderedStart == (mask&30 == 0))
        #expect(policy.permitsLiveStart == (mask&1 == 0))
        #expect(policy.needsRenderedStop == (mask&1 != 0))
    }
}
