import Foundation

@main struct ObservationDisplayFenceChecks {
    static func main() {
        let fresh: Int64 = 150_000_000 // matches MobileAirSendGate.freshNS
        var checks = 0
        func check(_ result: Bool, _ label: String) {
            checks += 1
            precondition(result, label)
        }
        var gate = MobileObservationDisplayFence()
        check(gate.observe(10, now: 20, freshness: fresh), "first observation")
        check(!gate.expire(now: 10 + fresh - 1, freshness: fresh), "last fresh nanosecond")
        check(gate.expire(now: 10 + fresh, freshness: fresh), "exact expiry")
        check(!gate.observe(10, now: 10 + fresh, freshness: fresh), "expired replay")
        gate = .init()
        check(gate.observe(100, now: 101, freshness: fresh), "fresh")
        check(!gate.observe(100, now: 102, freshness: fresh), "duplicate")
        check(gate.expire(now: 103, freshness: fresh), "duplicate cleared marker")
        check(!gate.observe(99, now: 104, freshness: fresh), "regressed observation")
        check(gate.observe(105, now: 106, freshness: fresh), "newer observation")
        check(!gate.observe(109, now: 108, freshness: fresh), "future")
        check(gate.expire(now: 108, freshness: fresh), "future cleared marker")
        check(!gate.observe(106, now: 107, freshness: fresh), "regressed receipt")
        check(gate.observe(109, now: 109, freshness: fresh), "recovery with newer receipt")
        check(!gate.observe(nil, now: 110, freshness: fresh), "missing stamp")
        check(!gate.observe(110, now: nil, freshness: fresh), "missing clock")
        check(!gate.observe(-1, now: 111, freshness: fresh), "negative stamp")
        check(!gate.observe(111, now: 111, freshness: 0), "invalid duration")
        check(gate.observe(112, now: 112, freshness: fresh), "reacquire")
        check(gate.expire(now: nil, freshness: fresh), "missing clock expires")
        print("\(checks)/\(checks) observation display fence checks PASS")
    }
}
