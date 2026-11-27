import Foundation
import Testing
@testable import NoSpeakerCore

@Test(arguments: [NativeHelperRelativeClutch.Surface.trackpad, .magicMouse], [false, true])
func relativeWatchdogChecksLeaseOnlyDuringActiveContact(surface: NativeHelperRelativeClutch.Surface, integerClock: Bool) {
    typealias Session = NativeHelperRelativeSession
    typealias Clutch = NativeHelperRelativeClutch
    for clean in [false, true] {
        for offset: Int64 in [0, 31_250_000, 93_750_000, 125_000_000] {
            let monitor = UUID(), registration = UUID()
            let lanes: [Clutch.Axis: Clutch.Lane] = [.x: .init(reference: 8192, upper: 16383)]
            var session = (integerClock
                ? Session(source: surface, monitor: monitor, registration: registration, afterSequence: 0,
                          afterAcquisitionNS: 0, maximumAgeNS: 125_000_000, lanes: lanes)
                : Session(source: surface, monitor: monitor, registration: registration, afterSequence: 0,
                          afterAcquisitionNS: 0, maximumAge: 0.125, lanes: lanes))!
            var now: Int64 = 1_000_000_000, sequence: UInt64 = 0
            var lease = false, leaseReads = 0, cleanupOK = clean
            var begins = 0, moves = 0, retirements: [Bool] = []
            func checkLease() -> Bool { leaseReads += 1; return lease }
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
                        permits: { true }, activeLeaseValid: checkLease, begin: begin, move: move, retire: retire)
                }
                return session.receive(frame, monitor: monitor, sequence: sequence, now: Double(now)/1e9,
                    permits: { true }, activeLeaseValid: checkLease, begin: begin, move: move, retire: retire)
            }
            func poll() -> Session.Result {
                if integerClock { return session.expire(nowNS: now, activeLeaseValid: checkLease, retire: retire) }
                return session.expire(now: Double(now)/1e9, activeLeaseValid: checkLease, retire: retire)
            }
            #expect(poll() == .ignored)
            #expect(leaseReads == 0 && retirements.isEmpty)
            cleanupOK = true
            #expect(feed(nil) == .waiting)
            #expect(poll() == .ignored) // neutral is not an active lease
            #expect(leaseReads == 0)
            lease = true
            #expect(feed(0.5) == .anchored)
            let before = leaseReads
            #expect(poll() == .ignored)
            #expect(leaseReads == before + 1)
            lease = false; cleanupOK = clean; now += offset
            #expect(poll() == .retired)
            #expect(retirements == [true, false])
            #expect(leaseReads == before + 2)
            let retiredReads = leaseReads
            #expect(poll() == .ignored)
            #expect(leaseReads == retiredReads && retirements == [true, false])
            lease = true
            #expect(feed(0.75) == .waiting)
            #expect(begins == 1 && moves == 0)
            cleanupOK = false
            #expect(feed(nil) == .retired)
            cleanupOK = true
            #expect(feed(0.75) == .waiting)
            #expect(feed(nil) == .waiting)
            #expect(feed(0.5) == .anchored)
            #expect(feed(0.75) == .accepted)
            #expect(begins == 2 && moves == 1)
            #expect(session.close(retire: retire) == .retired)
            let closedReads = leaseReads, closedRetirements = retirements
            #expect(poll() == .ignored)
            #expect(leaseReads == closedReads && retirements == closedRetirements)
        }
    }
}

@Test(arguments: [NativeHelperRelativeClutch.Surface.trackpad, .magicMouse], [false, true])
func relativeBindingWatchdogForwardsLeaseAndPreservesTerminalClose(surface: NativeHelperRelativeClutch.Surface, loseLive: Bool) throws {
    typealias Clutch = NativeHelperRelativeClutch
    typealias Binding = NativeHelperRelativeInputBinding
    let monitor = UUID(), registration = UUID()
    let boundary = try #require(NativeHelperRelativeArmBoundary(source: surface, registration: registration,
        afterSequence: 0, afterAcquisitionNS: 0))
    let config = try #require(NativeHelperRelativeSingleChannel(settings: .init(), enabled: [.x],
        channel: 2, vibratoCC: 74, expressionCC: 11))
    var binding = try #require(Binding(boundary: boundary, monitor: monitor, configuration: config, orientation: .horizontal))
    var now: Int64 = 1_000_000_000, sequence: UInt64 = 0
    var lease = false, live = true, leaseReads = 0, begins = 0, moves = 0
    var retirements: [Bool] = []
    func checkLease() -> Bool { leaseReads += 1; return lease }
    func retire(_ neutral: Bool, _: NativeHelperRelativeOutputPlan) -> Bool {
        retirements.append(neutral); return true
    }
    func feed(_ x: Double?) -> Binding.Result {
        now += 10_000_000; sequence += 1
        let contacts: [Clutch.Contact] = x.map { [.init(surface: surface, id: 1, x: $0, y: 0.5, contactSize: 0.5)] } ?? []
        let frame = Clutch.SourceFrame(surface: surface, rawDownCount: contacts.count, sourceConsistent: true,
            contacts: contacts, receipt: Double(now)/1e9, nativeRegistration: registration, acquisitionNS: now)
        let timestamp = now, admitted = live
        return binding.receive(frame, source: surface, monitor: monitor, sequence: sequence,
            clock: { timestamp }, live: { admitted }, activeLeaseValid: checkLease,
            begin: { _, permit in guard permit() else { return false }; begins += 1; return true },
            move: { _, permit in guard permit() else { return false }; moves += 1; return true }, retire: retire)
    }
    func poll() -> Binding.Result {
        binding.poll(nowNS: now, live: live, activeLeaseValid: checkLease, retire: retire)
    }
    #expect(poll() == .ignored)
    #expect(leaseReads == 0)
    #expect(feed(nil) == .waiting)
    lease = true
    #expect(feed(0.5) == .anchored)
    let before = leaseReads
    #expect(poll() == .ignored)
    #expect(leaseReads == before + 1)
    lease = false; live = !loseLive
    #expect(poll() == .retired)
    #expect(leaseReads == before + (loseLive ? 1 : 2))
    #expect(retirements == [true, false])
    live = true; lease = true
    #expect(poll() == .ignored)
    #expect(feed(0.75) == (loseLive ? .ignored : .waiting))
    #expect(feed(nil) == (loseLive ? .ignored : .waiting))
    #expect(feed(0.5) == (loseLive ? .ignored : .anchored))
    #expect(begins == (loseLive ? 1 : 2) && moves == 0)
}
