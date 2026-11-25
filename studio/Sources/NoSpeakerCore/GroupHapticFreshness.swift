import Foundation

/// Independent actuator freshness fence. A stalled host cannot keep a
/// held frame sounding indefinitely. Terminal until explicit new Start.
public struct GroupHapticFreshness: Sendable {
    public static let maximumAge = 0.1
    private var last:Double?
    public private(set) var retired = false
    public init() {}

    @discardableResult
    public mutating func refresh(now:Double) -> Bool {
        guard !retired else { return false }
        guard now.isFinite,now >= 0,last.map({ now >= $0 && now-$0 < Self.maximumAge }) ?? true else {
            retired = true; return false
        }
        last = now
        return true
    }

    @discardableResult
    public mutating func check(now:Double) -> Bool {
        guard !retired else { return false }
        guard let last,now.isFinite,now >= last,now-last < Self.maximumAge else {
            retired = true; return false
        }
        return true
    }
}
