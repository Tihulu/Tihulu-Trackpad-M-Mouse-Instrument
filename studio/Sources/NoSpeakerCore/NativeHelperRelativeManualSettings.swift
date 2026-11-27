/// Explicit manual references for the first native single-surface Helper
/// adapter. These are not receiver feedback or a last-delivered cache.
/// Settings are declarative; constructing lanes never activates output.
public struct NativeHelperRelativeManualSettings: Codable, Equatable, Sendable {
    public var x: RelativeControlSettings
    public var y: RelativeControlSettings
    public var contactSize: RelativeControlSettings
    public var smoothingMS: Int

    public init(x: RelativeControlSettings = .init(reference: 8192.0 / 16383),
                y: RelativeControlSettings = .init(reference: 0),
                contactSize: RelativeControlSettings = .init(reference: 1),
                smoothingMS: Int = 0) {
        self.x = x; self.y = y; self.contactSize = contactSize
        self.smoothingMS = smoothingMS
    }

    public var isValid: Bool {
        (0...250).contains(smoothingMS) && [x, y, contactSize].allSatisfy {
            $0.isValid && $0.effectiveSource == .manual
        }
    }

    /// X is a 14-bit bend lane; Y and contact size are 7-bit expressive
    /// controller lanes. Disabled assignments create no lane or reference.
    /// The host validates actual targets and receiver routing separately.
    public func lanes(enabled: Set<NativeHelperRelativeClutch.Axis>) -> [NativeHelperRelativeClutch.Axis: NativeHelperRelativeClutch.Lane]? {
        guard isValid, !enabled.isEmpty else { return nil }
        var result: [NativeHelperRelativeClutch.Axis: NativeHelperRelativeClutch.Lane] = [:]
        for axis in enabled {
            let settings: RelativeControlSettings
            let upper: Int
            switch axis {
            case .x: settings = x; upper = 16383
            case .y: settings = y; upper = 127
            case .contactSize: settings = contactSize; upper = 127
            }
            result[axis] = .init(reference: Int((settings.reference * Double(upper)).rounded()),
                                 upper: upper, gain: settings.gain, smoothingMS: smoothingMS)
        }
        return result
    }
}
