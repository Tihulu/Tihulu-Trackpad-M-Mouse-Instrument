/// Immutable orientation snapshot for one selected native Relative session.
/// Changing the selection or orientation requires closing/rearming the host
/// session. Never normalize an incomplete raw observation into valid input.
public struct NativeHelperRelativeOrientation: Sendable {
    public typealias Clutch = NativeHelperRelativeClutch
    public let selectedSurface: Clutch.Surface
    public let magicMouseOrientation: SurfaceOrientation

    public init(selectedSurface: Clutch.Surface, magicMouseOrientation: SurfaceOrientation) {
        self.selectedSurface = selectedSurface
        self.magicMouseOrientation = magicMouseOrientation
    }

    public func project(_ frame: Clutch.SourceFrame) -> Clutch.SourceFrame {
        guard frame.surface == selectedSurface, frame.surface == .magicMouse,
              magicMouseOrientation == .vertical, frame.isComplete else { return frame }
        let contacts = frame.contacts.map { contact in
            let (x, y) = magicMouseOrientation.transformed(x: contact.x, y: contact.y)
            return Clutch.Contact(surface: contact.surface, id: contact.id, x: x, y: y,
                                  contactSize: contact.contactSize)
        }
        return .init(surface: frame.surface, rawDownCount: frame.rawDownCount,
                     sourceConsistent: frame.sourceConsistent, contacts: contacts,
                     receipt: frame.receipt, nativeRegistration: frame.nativeRegistration,
                     acquisitionNS: frame.acquisitionNS)
    }
}
