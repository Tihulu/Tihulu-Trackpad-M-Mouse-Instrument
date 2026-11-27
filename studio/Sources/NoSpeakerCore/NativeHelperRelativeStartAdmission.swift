import Foundation

/// Bind the explicitly selected manual request to the physical arm boundary.
/// The caller must still verify the current monitor and registration and own
/// one serialized binding lifetime. Constructing a binding sends no MIDI.
public extension NativeHelperRelativeInputBinding {
    init?(request: NativeHelperRelativeStartRequest, boundary: NativeHelperRelativeArmBoundary,
          monitor: UUID) {
        guard request.surface == boundary.source else { return nil }
        self.init(boundary: boundary, monitor: monitor, configuration: request.output,
                  orientation: request.orientation)
    }
}
