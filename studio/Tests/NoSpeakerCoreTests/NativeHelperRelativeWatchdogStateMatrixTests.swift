import Foundation
import Testing
@testable import NoSpeakerCore

/// Independent phase/clock/lease matrix. No MIDI port is opened.
@Test(arguments: [NativeHelperRelativeClutch.Surface.trackpad, .magicMouse], [false, true])
func relativeWatchdogPhaseClockLeaseMatrix(surface: NativeHelperRelativeClutch.Surface, integerClock: Bool) {
    typealias Session = NativeHelperRelativeSession
    typealias Clutch = NativeHelperRelativeClutch
    // phase: idle, neutral-ready, active, retired, terminally closed
    // clock: same, fresh, exact deadline, regression, invalid, other domain
    for phase in 0..<5 {
        for clockCase in 0..<6 {
            for lease in [false, true] {
                for clean in [false, true] {
                    let monitor = UUID(), registration = UUID()
                    let lanes: [Clutch.Axis: Clutch.Lane] = [.x: .init(reference: 8192, upper: 16383)]
                    var session = (integerClock
                        ? Session(source: surface, monitor: monitor, registration: registration, afterSequence: 0,
                                  afterAcquisitionNS: 0, maximumAgeNS: 125_000_000, lanes: lanes)
                        : Session(source: surface, monitor: monitor, registration: registration, afterSequence: 0,
                                  afterAcquisitionNS: 0, maximumAge: 0.125, lanes: lanes))!
                    var now: Int64 = 1_000_000_000, sequence: UInt64 = 0
                    var reads = 0, begins = 0, moves = 0, retirements: [Bool] = []
                    var cleanupOK = true
                    func retire(_ neutral: Bool) -> Bool { retirements.append(neutral); return cleanupOK }
                    func feed(_ x: Double?) -> Session.Result {
                        now += 31_250_000; sequence += 1
                        let contacts: [Clutch.Contact] = x.map { [.init(surface: surface, id: 1, x: $0, y: 0.5, contactSize: 0.5)] } ?? []
                        let frame = Clutch.SourceFrame(surface: surface, rawDownCount: contacts.count, sourceConsistent: true,
                            contacts: contacts, receipt: Double(now)/1e9, nativeRegistration: registration, acquisitionNS: now)
                        func begin() -> Bool { begins += 1; return true }
                        func move(_: [Clutch.Axis: Int]) -> Bool { moves += 1; return true }
                        if integerClock {
                            return session.receive(frame, monitor: monitor, sequence: sequence, nowNS: now,
                                permits: { true }, activeLeaseValid: { true }, begin: begin, move: move, retire: retire)
                        }
                        return session.receive(frame, monitor: monitor, sequence: sequence, now: Double(now)/1e9,
                            permits: { true }, activeLeaseValid: { true }, begin: begin, move: move, retire: retire)
                    }
                    func poll(_ t: Int64, opposite: Bool = false, invalid: Bool = false, leaseOK: Bool = true) -> Session.Result {
                        func check() -> Bool { reads += 1; return leaseOK }
                        if integerClock != opposite {
                            return session.expire(nowNS: invalid ? -1 : t, activeLeaseValid: check, retire: retire)
                        }
                        return session.expire(now: invalid ? .nan : Double(t)/1e9, activeLeaseValid: check, retire: retire)
                    }
                    if phase >= 1 { #expect(feed(nil) == .waiting) }
                    if phase >= 2 { #expect(feed(0.5) == .anchored) }
                    if phase == 3 { #expect(poll(now, leaseOK: false) == .retired) }
                    if phase == 4 { #expect(session.close(retire: retire) == .retired) }
                    // Establish high water for the idle phase too.
                    if phase == 0 { #expect(poll(now) == .ignored) }
                    let priorReads = reads, priorRetirements = retirements.count
                    let priorBegins = begins, priorMoves = moves
                    cleanupOK = clean
                    let timestamp = now + [0, 31_250_000, 125_000_000, -31_250_000, 0, 0][clockCase]
                    let result = poll(timestamp, opposite: clockCase == 5, invalid: clockCase == 4, leaseOK: lease)
                    let terminal = phase == 4 || clockCase == 5
                    let shouldRetire = phase != 4 && (clockCase == 5 ||
                        ((phase == 1 || phase == 2) && (clockCase == 3 || clockCase == 4)) ||
                        (phase == 2 && clockCase < 3 && (!lease || clockCase == 2)))
                    let shouldRead = phase == 2 && clockCase < 3
                    #expect(result == (shouldRetire ? .retired : .ignored))
                    #expect(reads - priorReads == (shouldRead ? 1 : 0))
                    #expect(retirements.count - priorRetirements == (shouldRetire ? 1 : 0))
                    if shouldRetire { #expect(retirements.last == false) }
                    #expect(begins == priorBegins && moves == priorMoves)
                    // A valid future poll cannot produce a neutral or repeat cleanup.
                    // Healthy active cases are first advanced by a genuine held sample.
                    if phase == 2 && !shouldRetire && !terminal {
                        now = max(now, timestamp)
                        #expect(feed(0.5) == .accepted)
                        #expect(moves == priorMoves)
                        #expect(poll(now) == .ignored)
                    } else {
                        now = max(now, timestamp)
                        let afterReads = reads, afterRetirements = retirements.count
                        #expect(poll(now) == .ignored)
                        #expect(reads == afterReads && retirements.count == afterRetirements)
                        cleanupOK = true
                        let expected: Session.Result = terminal ? .ignored : (phase == 1 && !shouldRetire ? .anchored : .waiting)
                        #expect(feed(0.5) == expected)
                        #expect(moves == priorMoves)
                    }
                }
            }
        }
    }
}
