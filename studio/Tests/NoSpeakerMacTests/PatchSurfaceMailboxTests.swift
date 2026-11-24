#if os(macOS)
import Testing
@testable import NoSpeakerMac

@Test func patchMailboxOverflowIsLatchedAndCloseRejectsFrames() {
    let mailbox = PatchSurfaceMailbox()
    let frame = SurfaceTouchFrame(surface: .trackpad, contacts: [], timestamp: 0, frameNumber: 1)
    for _ in 0..<65 { mailbox.submit(frame) }
    let fault = mailbox.drain()
    #expect(fault.overflow && fault.samples.isEmpty)
    mailbox.close()
    mailbox.submit(frame)
    #expect(mailbox.drain().samples.isEmpty)
}
#endif
