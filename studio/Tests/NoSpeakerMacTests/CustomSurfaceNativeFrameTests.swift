#if os(macOS)
import Testing
import NoSpeakerCore
@testable import NoSpeakerMac

@Test func customNativeFramePreservesReceiptAndTopLeftCoordinates() throws {
    let contact = SurfaceContact(id: 7, surface: .trackpad, state: 3, isDown: true, x: 0.25, y: 0.75, size: 0.1)
    let frame = SurfaceTouchFrame(surface: .trackpad, contacts: [contact], timestamp: 999, frameNumber: 4,
                                  acquisitionNS: 42, validNativeEnvelope: true)
    let sample = try #require(CustomSurfaceNativeFrame(frame: frame, orientation: .init()))
    #expect(sample.surface == .trackpad)
    #expect(sample.observedAt == 42 && sample.sequence == 4)
    #expect(sample.contacts == [.init(id: 7, x: 0.25, y: 0.25)])
}

@Test func customNativeFrameDoesNotTurnMalformedInputIntoNeutral() throws {
    let neutral = SurfaceTouchFrame(surface: .trackpad, contacts: [], timestamp: 0, frameNumber: 1,
                                    acquisitionNS: 2, validNativeEnvelope: true)
    #expect(CustomSurfaceNativeFrame(frame: neutral, orientation: .init())?.contacts.isEmpty == true)
    let malformed = SurfaceTouchFrame(surface: .trackpad, contacts: [], timestamp: 0, frameNumber: 1,
                                      acquisitionNS: 2, validNativeEnvelope: false)
    #expect(CustomSurfaceNativeFrame(frame: malformed, orientation: .init()) == nil)
    let synthetic = SurfaceTouchFrame(surface: .trackpad, contacts: [], timestamp: 0, frameNumber: 1)
    #expect(CustomSurfaceNativeFrame(frame: synthetic, orientation: .init()) == nil)
    let invalid = SurfaceContact(id: 7, surface: .trackpad, state: 3, isDown: true, x: .nan, y: 0.5, size: 1)
    let bad = SurfaceTouchFrame(surface: .trackpad, contacts: [invalid], timestamp: 0, frameNumber: 1,
                                acquisitionNS: 2, validNativeEnvelope: true)
    #expect(CustomSurfaceNativeFrame(frame: bad, orientation: .init()) == nil)
}
#endif
