import Foundation
import Testing
@testable import NoSpeakerCore

private typealias ClockSession = NativeHelperRelativeSession
private typealias ClockClutch = NativeHelperRelativeClutch
private struct ClockDriver {
    let monitor = UUID(), registration = UUID()
    let surface: ClockClutch.Surface
    var session: ClockSession
    var calls: [String] = []
    var sequence: UInt64 = 0

    init(_ surface: ClockClutch.Surface) {
        self.surface = surface
        session = ClockSession(source: surface, monitor: monitor, registration: registration,
            afterSequence: 0, afterAcquisitionNS: 0, maximumAge: 0.125,
            lanes: [.x: .init(reference: 8192, upper: 16383)])!
    }
    mutating func feed(_ ns: Int64, _ now: Double, x: Double? = nil, foreign: Bool = false) -> ClockSession.Result {
        sequence += 1
        let contacts: [ClockClutch.Contact] = x.map { [.init(surface: surface, id: 1, x: $0, y: 0.5, contactSize: 0.5)] } ?? []
        let frame = ClockClutch.SourceFrame(surface: surface, rawDownCount: contacts.count,
            sourceConsistent: true, contacts: contacts, receipt: Double(ns)/1e9,
            nativeRegistration: registration, acquisitionNS: ns)
        var log: [String] = []
        let result = session.receive(frame, monitor: foreign ? UUID() : monitor, sequence: sequence, now: now,
            permits: { true }, activeLeaseValid: { true }, begin: { log.append("begin"); return true },
            move: { _ in log.append("move"); return true }, retire: { log.append("retire:\($0)"); return true })
        calls += log
        return result
    }
    mutating func tick(_ now: Double) -> ClockSession.Result {
        var log: [String] = []
        let result = session.expire(now: now, retire: { log.append("retire:\($0)"); return true })
        calls += log
        return result
    }
}

@Test(arguments: [ClockClutch.Surface.trackpad, .magicMouse], Array(0..<4))
func relativeHostClockRegressionRevokesAdmission(surface: NativeHelperRelativeClutch.Surface, stage: Int) {
    for base in [Int64(1), 100, 100000, 100000000] {
        let n = base * 1_000_000_000, t = Double(base)
        var d = ClockDriver(surface)
        #expect(d.feed(n,t+0.0625) == .waiting)
        if stage != 0 { #expect(d.feed(n+31_250_000,t+0.09375,x:0.5) == .anchored) }
        if stage == 2 { #expect(d.tick(t+0.109375) == .ignored) }
        if stage == 3 { #expect(d.feed(n+46_875_000,t+0.109375,x:0.75) == .accepted) }
        let before = d.calls.count
        let now = t + (stage == 0 ? 0.046875 : 0.078125)
        let result = stage == 2 ? d.tick(now) : d.feed(n+(stage == 0 ? 31_250_000 : 62_500_000),now,x:0.9)
        #expect(result == .retired)
        #expect(Array(d.calls.dropFirst(before)) == ["retire:false"])
        let after = d.calls.count
        #expect(d.feed(n+125_000_000,t+0.125,x:0.8) == .waiting)
        #expect(d.calls.count == after)
        #expect(d.feed(n+156_250_000,t+0.15625) == .waiting)
        #expect(d.feed(n+187_500_000,t+0.1875,x:0.5) == .anchored)
    }
}

@Test(arguments: [ClockClutch.Surface.trackpad, .magicMouse], [-Double.infinity, .nan, -1.0, 1.03125])
func relativeHostClockInvalidIdleWatchdogRevokesNeutralOnce(surface: NativeHelperRelativeClutch.Surface, badClock: Double) {
    var d = ClockDriver(surface)
    #expect(d.feed(1_000_000_000,1.0625) == .waiting)
    #expect(d.tick(badClock) == .retired)
    #expect(d.calls == ["retire:true","retire:false"])
    #expect(d.tick(badClock) == .ignored)
    #expect(d.calls.count == 2)
    #expect(d.feed(1_062_500_000,1.0625,x:0.5) == .waiting)
    #expect(d.calls.count == 2)
    #expect(d.feed(1_093_750_000,1.09375) == .waiting)
    #expect(d.feed(1_125_000_000,1.125,x:0.5) == .anchored)
}

@Test(arguments: [ClockClutch.Surface.trackpad, .magicMouse])
func relativeHostClockWatermarkSurvivesFaultAndIgnoresForeignObservation(surface: NativeHelperRelativeClutch.Surface) {
    var d = ClockDriver(surface)
    #expect(d.tick(1.0625) == .ignored)
    #expect(d.feed(1_000_000_000,1.03125) == .retired)
    #expect(d.feed(1_015_625_000,1.046875) == .retired)
    #expect(d.feed(1_031_250_000,1.0625) == .waiting)
    #expect(d.feed(1_046_875_000,100,foreign:true) == .ignored)
    #expect(d.feed(1_046_875_000,1.0625,x:0.5) == .anchored)
    #expect(d.calls == ["retire:false","retire:false","retire:true","begin"])
}
