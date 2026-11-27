import Foundation
import Testing
@testable import NoSpeakerCore

private typealias ExactSession = NativeHelperRelativeSession
private typealias ExactClutch = NativeHelperRelativeClutch
private struct ExactClockDriver {
    let monitor = UUID(), registration = UUID()
    let surface: ExactClutch.Surface
    var session: ExactSession
    var sequence: UInt64 = 0
    var releases = 0, begins = 0, moves = 0

    init(_ surface: ExactClutch.Surface) {
        self.surface = surface
        session = ExactSession(source: surface, monitor: monitor, registration: registration,
            afterSequence: 0, afterAcquisitionNS: 0, maximumAgeNS: 150_000_000,
            lanes: [.x: .init(reference: 8192, upper: 16383)])!
    }
    mutating func feed(_ acquired: Int64, now: Int64, x: Double? = nil) -> ExactSession.Result {
        sequence += 1
        let contacts: [ExactClutch.Contact] = x.map { [.init(surface: surface, id: 1, x: $0, y: 0.5, contactSize: 0.5)] } ?? []
        let frame = ExactClutch.SourceFrame(surface: surface, rawDownCount: contacts.count, sourceConsistent: true,
            contacts: contacts, receipt: Double(acquired)/1e9, nativeRegistration: registration, acquisitionNS: acquired)
        var r = 0, b = 0, m = 0
        let result = session.receive(frame, monitor: monitor, sequence: sequence, nowNS: now, permits: { true },
            activeLeaseValid: { true }, begin: { b += 1; return true }, move: { _ in m += 1; return true },
            retire: { if !$0 { r += 1 }; return true })
        releases += r; begins += b; moves += m
        return result
    }
    mutating func poll(_ now: Int64) -> ExactSession.Result {
        var r = 0
        let result = session.expire(nowNS: now, retire: { neutral in
            #expect(!neutral); r += 1; return true
        })
        releases += r
        return result
    }
}

@Test(arguments: [ExactClutch.Surface.trackpad, .magicMouse], [Int64(1_000_000_000), 100_000_000_000, 100_000_000_000_000, 100_000_000_000_000_000])
func relativeIntegerClockExactDeadline(surface: NativeHelperRelativeClutch.Surface, base: Int64) {
    for offset in 0..<256 {
        let anchor = base + 31_250_000 + Int64(offset)*1024
        for delta: Int64 in [149_999_999, 150_000_000, 150_000_001] {
            let now = anchor + delta
            let expired = delta >= 150_000_000
            for watchdog in [true, false] {
                var d = ExactClockDriver(surface)
                #expect(d.feed(base, now: base) == .waiting)
                #expect(d.feed(anchor, now: anchor, x: 0.5) == .anchored)
                let result = watchdog ? d.poll(now) : d.feed(now-32_000_000, now: now, x: 0.75)
                #expect(result == (expired ? .retired : (watchdog ? .ignored : .accepted)))
                #expect(d.releases == (expired ? 1 : 0))
                #expect(d.moves == (!expired && !watchdog ? 1 : 0))
                if expired {
                    #expect(d.feed(now+32_000_000, now: now+32_000_000, x: 0.8) == .waiting)
                    #expect(d.begins == 1)
                    #expect(d.feed(now+64_000_000, now: now+64_000_000) == .waiting)
                    #expect(d.feed(now+96_000_000, now: now+96_000_000, x: 0.5) == .anchored)
                }
            }
            var fresh = ExactClockDriver(surface)
            #expect(fresh.feed(anchor, now: now) == (expired ? .retired : .waiting))
            #expect(fresh.releases == (expired ? 1 : 0))
        }
    }
}

@Test(arguments: [ExactClutch.Surface.trackpad, .magicMouse])
func relativeIntegerClockRejectsSubDoubleRegressionAndMixedDomain(surface: NativeHelperRelativeClutch.Surface) {
    let base: Int64 = 100_000_000_000_000_000
    var d = ExactClockDriver(surface)
    #expect(d.feed(base, now: base) == .waiting)
    let anchor = base+32_000_000
    #expect(d.feed(anchor, now: anchor, x: 0.5) == .anchored)
    let later = anchor+32_000_000
    #expect(Double(later)/1e9 == Double(later-1)/1e9)
    #expect(d.poll(later) == .ignored)
    #expect(d.poll(later-1) == .retired)
    #expect(d.releases == 1)
    #expect(d.poll(later-1) == .ignored)
    #expect(d.feed(anchor+16_000_000, now: later-1) == .retired)
    #expect(d.feed(later+32_000_000, now: later+32_000_000, x: 0.5) == .waiting)
    #expect(d.feed(later+64_000_000, now: later+64_000_000) == .waiting)
    #expect(d.feed(later+96_000_000, now: later+96_000_000, x: 0.5) == .anchored)
    #expect(d.session.expire(now: Double(later+96_000_000)/1e9, retire: { !$0 }) == .retired)
    #expect(d.feed(later+128_000_000, now: later+128_000_000) == .ignored)
}

@Test(arguments: [ExactClutch.Surface.trackpad, .magicMouse])
func relativeIntegerClockInvalidDomainsFailClosed(surface: NativeHelperRelativeClutch.Surface) {
    for invalid: Int64 in [-1, Int64.max] {
        var d = ExactClockDriver(surface)
        #expect(d.feed(1_000_000_000, now: 1_000_000_000) == .waiting)
        #expect(d.poll(invalid) == .retired)
        #expect(d.poll(invalid) == .ignored)
        #expect(d.releases == 1)
        #expect(d.feed(1_032_000_000, now: 1_032_000_000, x: 0.5) == .waiting)
    }
    var d = ExactClockDriver(surface)
    #expect(d.feed(1_000_000_000, now: 1_000_000_000) == .waiting)
    #expect(d.feed(1_032_000_000, now: 1_031_999_999, x: 0.5) == .retired)
    #expect(d.begins == 0)
    for invalid: Int64 in [-1, 0, Int64.max] {
        #expect(ExactSession(source: surface, monitor: UUID(), registration: UUID(), afterSequence: 0,
            afterAcquisitionNS: 0, maximumAgeNS: invalid, lanes: [.x: .init(reference: 8192, upper: 16383)]) == nil)
    }
}
