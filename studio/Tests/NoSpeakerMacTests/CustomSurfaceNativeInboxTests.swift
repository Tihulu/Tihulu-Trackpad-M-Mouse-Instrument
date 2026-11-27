#if os(macOS)
import Testing
import NoSpeakerCore
@testable import NoSpeakerMac

private func inboxFrame(_ n: Int, surface: TouchSurfaceKind = .trackpad, valid: Bool = true) -> SurfaceTouchFrame {
    .init(surface: surface, contacts: [], timestamp: 0, frameNumber: n, acquisitionNS: Int64(n), validNativeEnvelope: valid, rawNativeContactCount: 0)
}
@Test func customNativeInboxFiltersSurfaceAndPreArmFrames() {
    let inbox = CustomSurfaceNativeInbox(surface: .trackpad, orientation: .horizontal, notBefore: 10)
    inbox.submit(inboxFrame(9))
    inbox.submit(inboxFrame(10, surface: .magicMouse))
    inbox.submit(inboxFrame(11))
    inbox.submit(inboxFrame(12))
    let drained = inbox.drain()
    #expect(!drained.faulted)
    #expect(drained.samples.map(\.observedAt) == [11,12])
    #expect(inbox.drain().samples.isEmpty)
    inbox.close()
    inbox.submit(inboxFrame(13))
    #expect(inbox.drain().samples.isEmpty)
}
@Test func customNativeInboxOverflowAndInvalidEnvelopeAreTerminal() {
    let inbox = CustomSurfaceNativeInbox(surface: .trackpad, orientation: .horizontal, notBefore: 0)
    for n in 1...65 { inbox.submit(inboxFrame(n)) }
    #expect(inbox.drain().faulted)
    inbox.submit(inboxFrame(66))
    #expect(inbox.drain().samples.isEmpty)
    let bad = CustomSurfaceNativeInbox(surface: .trackpad, orientation: .horizontal, notBefore: 0)
    bad.submit(inboxFrame(1))
    bad.submit(inboxFrame(2, valid: false))
    #expect(bad.drain().faulted)
    #expect(bad.drain().samples.isEmpty)
}
#endif

#if os(macOS)
@Test func customNativeInboxDiscardsProvisionalFramesAtActualArm() {
    let inbox = CustomSurfaceNativeInbox(surface: .trackpad, orientation: .horizontal, notBefore: 0)
    inbox.submit(inboxFrame(1))
    #expect(inbox.begin(at: 3))
    inbox.submit(inboxFrame(2))
    inbox.submit(inboxFrame(4))
    #expect(inbox.drain().samples.map(\.observedAt) == [4])
    inbox.close()
    #expect(!inbox.begin(at: 5))
}
#endif

#if os(macOS)
@Test func customNativeInboxRevokesAlreadyDrainedBatchAdmissionOnProducerFault() {
    let inbox = CustomSurfaceNativeInbox(surface: .trackpad, orientation: .horizontal, notBefore: 0)
    inbox.submit(inboxFrame(1))
    let batch = inbox.drain()
    #expect(batch.samples.count == 1)
    #expect(inbox.admitsDelivery)
    inbox.submit(inboxFrame(2, valid: false))
    #expect(!inbox.admitsDelivery)
    #expect(!inbox.begin(at: 3))
    let closed = CustomSurfaceNativeInbox(surface: .trackpad, orientation: .horizontal, notBefore: 0)
    #expect(closed.admitsDelivery)
    closed.close()
    #expect(!closed.admitsDelivery)
}
#endif

#if os(macOS)
@Test func customNativeDiagnosticOnlyNeverAdmitsOrQueuesMIDIAndRetainsInvalidEvidence() {
    let inbox = CustomSurfaceNativeInbox(surface: .trackpad, orientation: .horizontal,
                                         notBefore: 10, diagnosticOnly: true)
    inbox.submit(inboxFrame(9))
    inbox.submit(inboxFrame(10, surface: .magicMouse))
    inbox.submit(inboxFrame(11, valid: false))
    for n in 12...100 { inbox.submit(inboxFrame(n)) }
    #expect(!inbox.admitsDelivery)
    #expect(inbox.drain().samples.isEmpty && !inbox.drain().faulted)
    #expect(inbox.captureEvidence().frames == 90)
    #expect(inbox.captureEvidence().invalidFrames == 1)
    inbox.close()
    inbox.submit(inboxFrame(101))
    #expect(inbox.captureEvidence().frames == 90)
}
@Test func customNativeLiveEvidencePreservesFaultAndResetsAtArmBoundary() {
    let inbox = CustomSurfaceNativeInbox(surface: .trackpad, orientation: .horizontal, notBefore: 0)
    inbox.submit(inboxFrame(1))
    #expect(inbox.captureEvidence().frames == 1)
    #expect(inbox.begin(at: 2))
    #expect(inbox.captureEvidence().frames == 0)
    inbox.submit(inboxFrame(3, valid: false))
    #expect(inbox.captureEvidence().invalidFrames == 1)
    #expect(!inbox.admitsDelivery)
    inbox.submit(inboxFrame(4))
    #expect(inbox.captureEvidence().frames == 1)
}
#endif

#if os(macOS)
@Test func customNativeInboxUnorderedProducerFrameRevokesDrainedBatch() {
    let inbox = CustomSurfaceNativeInbox(surface: .trackpad, orientation: .horizontal, notBefore: 0)
    inbox.submit(inboxFrame(2))
    #expect(inbox.drain().samples.count == 1)
    inbox.submit(inboxFrame(1))
    #expect(!inbox.admitsDelivery)
    #expect(inbox.queueEvidence().fault == .unorderedFrame)
    #expect(inbox.queueEvidence().peak == 1)
    #expect(inbox.drain().faulted)
}
@Test func customNativeInboxReportsDistinctOverflowAndInvalidFaults() {
    let full = CustomSurfaceNativeInbox(surface: .trackpad, orientation: .horizontal, notBefore: 0)
    for n in 1...65 { full.submit(inboxFrame(n)) }
    #expect(full.queueEvidence().peak == 64 && full.queueEvidence().fault == .overflow)
    let invalid = CustomSurfaceNativeInbox(surface: .trackpad, orientation: .horizontal, notBefore: 0)
    invalid.submit(inboxFrame(1, valid: false))
    #expect(invalid.queueEvidence().peak == 0 && invalid.queueEvidence().fault == .invalidFrame)
}
#endif
