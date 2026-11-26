#if os(macOS)
import Testing
import NoSpeakerCore
@testable import NoSpeakerMac

private func inboxFrame(_ n: Int, surface: TouchSurfaceKind = .trackpad, valid: Bool = true) -> SurfaceTouchFrame {
    .init(surface: surface, contacts: [], timestamp: 0, frameNumber: n, acquisitionNS: Int64(n), validNativeEnvelope: valid)
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
