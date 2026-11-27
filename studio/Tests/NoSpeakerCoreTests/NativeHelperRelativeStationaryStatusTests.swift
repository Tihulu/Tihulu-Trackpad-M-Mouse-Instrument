import Foundation
import Testing
@testable import NoSpeakerCore

@Test(arguments: [NativeHelperRelativeClutch.Surface.trackpad, .magicMouse], [false, true])
func relativeHeldStatusRemainsActiveWithoutRedundantOutput(surface: NativeHelperRelativeClutch.Surface, integerClock: Bool) {
    typealias Clutch = NativeHelperRelativeClutch
    typealias Session = NativeHelperRelativeSession
    for smoothing in [0, 25, 250] {
        for axis in Clutch.Axis.allCases {
            let monitor = UUID(), registration = UUID()
            let upper = axis == .x ? 16383 : 127
            let lanes: [Clutch.Axis: Clutch.Lane] = [axis: .init(reference: upper, upper: upper, smoothingMS: smoothing)]
            var session = (integerClock
                ? Session(source: surface, monitor: monitor, registration: registration, afterSequence: 0,
                          afterAcquisitionNS: 0, maximumAgeNS: 150_000_000, lanes: lanes)
                : Session(source: surface, monitor: monitor, registration: registration, afterSequence: 0,
                          afterAcquisitionNS: 0, maximumAge: 0.15, lanes: lanes))!
            var now: Int64 = 1_000_000_000, sequence: UInt64 = 0
            var calls: [String] = [], live = true, lease = true
            func push(_ value: Double?, id: Int = 1, advance: Int64 = 10_000_000) -> Session.Result {
                now += advance; sequence += 1
                let contacts: [Clutch.Contact] = value.map { [.init(surface: surface, id: id, x: $0, y: $0, contactSize: $0)] } ?? []
                let frame = Clutch.SourceFrame(surface: surface, rawDownCount: contacts.count, sourceConsistent: true,
                    contacts: contacts, receipt: Double(now)/1e9, nativeRegistration: registration, acquisitionNS: now)
                func begin() -> Bool { calls.append("begin"); return true }
                func move(_ values: [Clutch.Axis: Int]) -> Bool { calls.append("move:\(values[axis] ?? -1)"); return true }
                func retire(_ neutral: Bool) -> Bool { calls.append("retire:\(neutral)"); return true }
                if integerClock {
                    return session.receive(frame, monitor: monitor, sequence: sequence, nowNS: now,
                        permits: { live }, activeLeaseValid: { lease }, begin: begin, move: move, retire: retire)
                }
                return session.receive(frame, monitor: monitor, sequence: sequence, now: Double(now)/1e9,
                    permits: { live }, activeLeaseValid: { lease }, begin: begin, move: move, retire: retire)
            }
            #expect(push(0.5) == .waiting)
            #expect(calls.isEmpty)
            #expect(push(nil) == .waiting)
            #expect(push(0.5) == .anchored)
            let before = calls
            for value in [0.5, 0.50001, 0.75, 1.0, 0.9, 0.9] {
                #expect(push(value) == .accepted)
            }
            #expect(calls == before) // stationary, sub-step and saturated: no output
            live = false
            #expect(push(0.9) == .retired)
            #expect(calls.last == "retire:false")
            live = true
            #expect(push(0.9) == .waiting)
            #expect(push(nil) == .waiting)
            #expect(push(0.5) == .anchored)
            lease = false
            #expect(push(0.5) == .retired)
            #expect(calls.last == "retire:false")
            lease = true
            #expect(push(nil) == .waiting)
            #expect(push(0.5) == .anchored)
            #expect(push(0.5, id: 2) == .retired)
            #expect(push(nil) == .waiting)
            #expect(push(0.5) == .anchored)
            #expect(push(0.5, advance: 160_000_000) == .retired)
            #expect(push(nil) == .waiting)
            #expect(push(0.5) == .anchored)
            #expect(push(nil) == .waiting)
            #expect(calls.last == "retire:true")
        }
    }
}

@Test(arguments: [NativeHelperRelativeClutch.Surface.trackpad, .magicMouse], [false, true])
func relativeHeldStatusPreservesMovementAndWatchdog(surface: NativeHelperRelativeClutch.Surface, integerClock: Bool) {
    typealias Clutch = NativeHelperRelativeClutch
    typealias Session = NativeHelperRelativeSession
    let monitor = UUID(), registration = UUID()
    let lanes: [Clutch.Axis: Clutch.Lane] = [.x: .init(reference: 8192, upper: 16383)]
    var session = (integerClock
        ? Session(source: surface, monitor: monitor, registration: registration, afterSequence: 0,
                  afterAcquisitionNS: 0, maximumAgeNS: 125_000_000, lanes: lanes)
        : Session(source: surface, monitor: monitor, registration: registration, afterSequence: 0,
                  afterAcquisitionNS: 0, maximumAge: 0.125, lanes: lanes))!
    var now: Int64 = 1_000_000_000, sequence: UInt64 = 0
    var moves: [Int] = [], retirements: [Bool] = [], begins = 0
    func push(_ value: Double?) -> Session.Result {
        now += 31_250_000; sequence += 1
        let contacts: [Clutch.Contact] = value.map { [.init(surface: surface, id: 1, x: $0, y: 0.5, contactSize: 0.5)] } ?? []
        let frame = Clutch.SourceFrame(surface: surface, rawDownCount: contacts.count, sourceConsistent: true,
            contacts: contacts, receipt: Double(now)/1e9, nativeRegistration: registration, acquisitionNS: now)
        func begin() -> Bool { begins += 1; return true }
        func move(_ values: [Clutch.Axis: Int]) -> Bool { moves.append(values[.x] ?? -1); return true }
        func retire(_ neutral: Bool) -> Bool { retirements.append(neutral); return true }
        if integerClock {
            return session.receive(frame, monitor: monitor, sequence: sequence, nowNS: now,
                permits: { true }, activeLeaseValid: { true }, begin: begin, move: move, retire: retire)
        }
        return session.receive(frame, monitor: monitor, sequence: sequence, now: Double(now)/1e9,
            permits: { true }, activeLeaseValid: { true }, begin: begin, move: move, retire: retire)
    }
    func poll(after delta: Int64) -> Session.Result {
        func retire(_ neutral: Bool) -> Bool { retirements.append(neutral); return true }
        if integerClock { return session.expire(nowNS: now + delta, retire: retire) }
        return session.expire(now: Double(now + delta)/1e9, retire: retire)
    }
    #expect(push(nil) == .waiting)
    #expect(push(0.5) == .anchored)
    #expect(push(0.75) == .accepted)
    #expect(push(0.75) == .accepted)
    #expect(push(0.5) == .accepted)
    #expect(push(0.5) == .accepted)
    #expect(moves == [12288, 8192])
    #expect(begins == 1)
    #expect(poll(after: 93_750_000) == .ignored)
    #expect(poll(after: 125_000_000) == .retired)
    #expect(retirements == [true, false])
    now += 125_000_000
    #expect(push(0.5) == .waiting)
    #expect(push(nil) == .waiting)
    #expect(push(0.5) == .anchored)
    #expect(push(nil) == .waiting)
    #expect(begins == 2)
    #expect(moves == [12288, 8192])
    #expect(retirements == [true, false, true, true])
}
