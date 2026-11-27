import Foundation

/// Presentation only: never authorizes a note, renews a lease, or changes a
/// transport timestamp. A rejected observation clears the visible marker;
/// its successor must still be newer than the last admitted observation.
struct MobileObservationDisplayFence {
    private var watermark: Int64?
    private var receipt: Int64?
    private var visible: Int64?

    mutating func observe(_ stamp: Int64?, now: Int64?, freshness: Int64) -> Bool {
        guard let now, now >= 0, receipt.map({ now >= $0 }) ?? true else {
            visible = nil; return false
        }
        receipt = now
        guard let stamp, stamp >= 0, stamp <= now, freshness > 0,
              now - stamp < freshness, watermark.map({ stamp > $0 }) ?? true else {
            visible = nil; return false
        }
        watermark = stamp; visible = stamp
        return true
    }

    mutating func expire(now: Int64?, freshness: Int64) -> Bool {
        guard let now, now >= 0, receipt.map({ now >= $0 }) ?? true else {
            visible = nil; return true
        }
        receipt = now
        guard let visible, freshness > 0, now >= visible, now - visible < freshness else {
            self.visible = nil; return true
        }
        return false
    }
}
