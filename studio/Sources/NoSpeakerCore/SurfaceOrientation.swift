import Foundation

/// Physical orientation for Magic Mouse gesture mapping. The Force Touch
/// trackpad always stays in its native coordinate system.
public enum SurfaceOrientation: String, CaseIterable, Identifiable, Codable, Sendable {
    case horizontal = "Horizontal"
    case vertical = "Vertical"
    public var id: String { rawValue }

    public func transformed(x: Double, y: Double) -> (Double, Double) {
        let safeX = x.isFinite ? min(1, max(0, x)) : 0
        let safeY = y.isFinite ? min(1, max(0, y)) : 0
        switch self {
        case .horizontal: return (safeX, safeY)
        case .vertical: return (safeY, 1 - safeX)
        }
    }
}
