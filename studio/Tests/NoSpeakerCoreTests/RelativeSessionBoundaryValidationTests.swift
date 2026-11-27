import Foundation
import Testing
@testable import NoSpeakerCore

struct RelativeSessionBoundaryValidationTests {
    typealias Session = NativeHelperRelativeSession
    typealias Clutch = NativeHelperRelativeClutch

    @Test(arguments: [Clutch.Surface.trackpad, .magicMouse], [false, true])
    func constructorsRejectImpossibleBoundary(surface: Clutch.Surface, integerClock: Bool) {
        let lanes: [Clutch.Axis: Clutch.Lane] = [.x: .init(reference: 8192, upper: 16383)]
        for sequence: UInt64 in [0, 1, UInt64.max - 2, UInt64.max - 1, UInt64.max] {
            for acquisition: Int64 in [Int64.min, -1, 0, 1, Int64.max - 2, Int64.max - 1, Int64.max] {
                let session: Session?
                if integerClock {
                    session = Session(source: surface, monitor: UUID(), registration: UUID(), afterSequence: sequence,
                                      afterAcquisitionNS: acquisition, maximumAgeNS: 150_000_000, lanes: lanes)
                } else {
                    session = Session(source: surface, monitor: UUID(), registration: UUID(), afterSequence: sequence,
                                      afterAcquisitionNS: acquisition, maximumAge: 0.15, lanes: lanes)
                }
                #expect((session != nil) == (sequence < UInt64.max && acquisition >= 0 && acquisition < Int64.max))
            }
        }
    }

    @Test(arguments: [Clutch.Surface.trackpad, .magicMouse], [false, true])
    func finalLegalPublicationDoesNotWrap(surface: Clutch.Surface, integerClock: Bool) throws {
        let monitor = UUID(), registration = UUID()
        let lanes: [Clutch.Axis: Clutch.Lane] = [.x: .init(reference: 8192, upper: 16383)]
        let initial = UInt64.max - 3
        let candidate: Session?
        if integerClock {
            candidate = Session(source: surface, monitor: monitor, registration: registration, afterSequence: initial,
                                afterAcquisitionNS: 0, maximumAgeNS: 150_000_000, lanes: lanes)
        } else {
            candidate = Session(source: surface, monitor: monitor, registration: registration, afterSequence: initial,
                                afterAcquisitionNS: 0, maximumAge: 0.15, lanes: lanes)
        }
        var session = try #require(candidate)
        var events: [String] = []
        func feed(_ sequence: UInt64, _ ns: Int64, x: Double?) -> Session.Result {
            let contacts: [Clutch.Contact] = x.map { [.init(surface: surface, id: 1, x: $0, y: 0.5, contactSize: 0.5)] } ?? []
            let seconds = Double(ns) / 1_000_000_000
            let frame = Clutch.SourceFrame(surface: surface, rawDownCount: contacts.count, sourceConsistent: true,
                contacts: contacts, receipt: seconds, nativeRegistration: registration, acquisitionNS: ns)
            let begin = { events.append("begin"); return true }
            let move: ([Clutch.Axis: Int]) -> Bool = { _ in events.append("move"); return true }
            let retire: (Bool) -> Bool = { events.append($0 ? "neutral" : "fault"); return true }
            if integerClock {
                return session.receive(frame, monitor: monitor, sequence: sequence, nowNS: ns, permits: { true },
                    activeLeaseValid: { true }, begin: begin, move: move, retire: retire)
            }
            return session.receive(frame, monitor: monitor, sequence: sequence, now: seconds, permits: { true },
                activeLeaseValid: { true }, begin: begin, move: move, retire: retire)
        }
        let neutral = feed(initial + 1, 1_000_000_000, x: nil)
        let anchor = feed(initial + 2, 1_031_250_000, x: 0.5)
        let movement = feed(UInt64.max, 1_062_500_000, x: 0.75)
        let wrapped = feed(0, 1_093_750_000, x: nil)
        let duplicate = feed(UInt64.max, 1_093_750_000, x: nil)
        #expect(neutral == .waiting)
        #expect(anchor == .anchored)
        #expect(movement == .accepted)
        #expect(wrapped == .ignored && duplicate == .ignored)
        #expect(events == ["neutral", "begin", "move"])
        let closed = session.close(retire: { events.append($0 ? "neutral" : "fault"); return true })
        #expect(closed == .retired)
        #expect(events == ["neutral", "begin", "move", "fault"])
    }
}
