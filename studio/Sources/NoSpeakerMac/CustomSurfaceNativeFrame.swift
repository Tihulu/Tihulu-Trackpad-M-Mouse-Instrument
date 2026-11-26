#if os(macOS)
import Foundation
import NoSpeakerCore

/// Strict adapter for a complete, source-local private touch callback.
/// A malformed envelope must never serve as a neutral arm handshake.
public struct CustomSurfaceNativeFrame: Sendable, Equatable {
    public let surface: CustomSurfacePadLayout.Surface
    public let contacts: [CustomSurfaceContactProjection.Contact]
    public let sequence: UInt64
    public let observedAt: Int64

    public init?(frame: SurfaceTouchFrame, orientation: SurfaceOrientation) {
        guard frame.validNativeEnvelope, let receipt = frame.acquisitionNS, receipt >= 0,
              frame.frameNumber >= 0,
              frame.contacts.count <= NativeTouchFramePolicy.maximumContacts,
              Set(frame.contacts.map(\.id)).count == frame.contacts.count else { return nil }
        surface = frame.surface == .trackpad ? .trackpad : .magicMouse
        sequence = UInt64(frame.frameNumber)
        observedAt = receipt
        var result: [CustomSurfaceContactProjection.Contact] = []
        for contact in frame.contacts {
            guard contact.surface == frame.surface, contact.id >= 0,
                  (3...5).contains(contact.state), contact.isDown == (contact.state != 5),
                  (0...1).contains(contact.x), (0...1).contains(contact.y),
                  contact.size.isFinite, contact.size >= 0 else { return nil }
            guard contact.isDown else { continue }
            let x = Double(contact.x), y = Double(contact.y)
            let oriented = frame.surface == .magicMouse ? orientation.transformed(x: x, y: y) : (x, y)
            // Private touch coordinates increase upward; layout Y starts at top.
            result.append(.init(id: contact.id, x: oriented.0, y: 1 - oriented.1))
        }
        contacts = result
    }
}
#endif
