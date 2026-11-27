import Foundation

/// UI setup preflight only; actual camera and session owners still check
/// permission, scene orientation and negotiated assignment independently.
enum MobileXYZSetupIssue: String, Equatable {
    case inactive = "Return to the active app."
    case noDepth = "Rear LiDAR scene depth is unavailable."
    case invalidVolume = "Set ordered calibration bounds with sufficient spacing."
    case invalidAxes = "Enable at least one valid helper axis."

    static func check(hasDepth: Bool, validVolume: Bool, usesControls: Bool,
                      axes: Int, foreground: Bool) -> Self? {
        if !foreground { return .inactive }
        if !hasDepth { return .noDepth }
        if !validVolume { return .invalidVolume }
        if usesControls && !(1...7).contains(axes) { return .invalidAxes }
        return nil
    }
}

/// Late permission callbacks can report status only for the current request.
/// No callback starts a sensor or connects a socket.
struct MobilePermissionRequestFence {
    private var ticket: UUID?
    var pending: Bool { ticket != nil }
    mutating func begin() -> UUID? {
        guard ticket == nil else { return nil }
        let next = UUID(); ticket = next
        return next
    }
    mutating func finish(_ candidate: UUID) -> Bool {
        guard ticket == candidate else { return false }
        ticket = nil
        return true
    }
    mutating func retire() { ticket = nil }
}
