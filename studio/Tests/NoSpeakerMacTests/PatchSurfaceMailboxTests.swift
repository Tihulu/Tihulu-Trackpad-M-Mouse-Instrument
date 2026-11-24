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

@Test func syntheticSurfaceNeverConsumesNativeMailboxCapacity() {
    let mailbox = PatchSurfaceMailbox(excludedSurface:.magicMouse)
    let synthetic = SurfaceTouchFrame(surface:.magicMouse,contacts:[],timestamp:0,frameNumber:1)
    let native = SurfaceTouchFrame(surface:.trackpad,contacts:[],timestamp:0,frameNumber:2)
    for _ in 0..<100 { mailbox.submit(synthetic) }
    mailbox.submit(native)
    let result = mailbox.drain()
    #expect(!result.overflow)
    #expect(result.samples.count == 1)
    #expect(result.samples.first?.frame.surface == .trackpad)
}
#endif
