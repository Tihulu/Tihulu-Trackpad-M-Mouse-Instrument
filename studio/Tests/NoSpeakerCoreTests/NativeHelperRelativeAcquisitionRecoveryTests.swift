import Foundation
import Testing
@testable import NoSpeakerCore

private typealias RecoverySession = NativeHelperRelativeSession
private typealias RecoveryClutch = NativeHelperRelativeClutch

@Test(arguments: [RecoveryClutch.Surface.trackpad, .magicMouse], Array(0..<4))
func relativeImpossibleAcquisitionCannotPoisonTrustedWatermark(surface: NativeHelperRelativeClutch.Surface, kind: Int) {
    for active in [false, true] {
        for integerClock in [false, true] {
            let monitor = UUID(), registration = UUID()
            let lanes: [RecoveryClutch.Axis: RecoveryClutch.Lane] = [.x: .init(reference: 8192, upper: 16383)]
            var session = (integerClock
                ? RecoverySession(source: surface, monitor: monitor, registration: registration,
                    afterSequence: 0, afterAcquisitionNS: 0, maximumAgeNS: 150_000_000, lanes: lanes)
                : RecoverySession(source: surface, monitor: monitor, registration: registration,
                    afterSequence: 0, afterAcquisitionNS: 0, maximumAge: 0.15, lanes: lanes))!
            var sequence: UInt64 = 0, calls: [String] = []
            let base: Int64 = 1_000_000_000
            func feed(_ acquired: Int64, now: Int64, down: Bool = false, receipt: Double? = nil) -> RecoverySession.Result {
                sequence += 1
                let contacts: [RecoveryClutch.Contact] = down ? [.init(surface: surface, id: 1, x: 0.5, y: 0.5, contactSize: 0.5)] : []
                let frame = RecoveryClutch.SourceFrame(surface: surface, rawDownCount: contacts.count,
                    sourceConsistent: true, contacts: contacts, receipt: receipt ?? Double(acquired)/1e9,
                    nativeRegistration: registration, acquisitionNS: acquired)
                func begin() -> Bool { calls.append("begin"); return true }
                func move(_: [RecoveryClutch.Axis: Int]) -> Bool { calls.append("move"); return true }
                func retire(_ neutral: Bool) -> Bool { calls.append("retire:\(neutral)"); return true }
                if integerClock {
                    return session.receive(frame, monitor: monitor, sequence: sequence, nowNS: now,
                        permits: { true }, activeLeaseValid: { true }, begin: begin, move: move, retire: retire)
                }
                return session.receive(frame, monitor: monitor, sequence: sequence, now: Double(now)/1e9,
                    permits: { true }, activeLeaseValid: { true }, begin: begin, move: move, retire: retire)
            }
            #expect(feed(base, now: base) == .waiting)
            if active { #expect(feed(base+32_000_000, now: base+32_000_000, down: true) == .anchored) }
            let invalidNow = base+64_000_000
            let impossible: Int64 = kind == 0 ? invalidNow+10_000_000_000 : kind == 1 ? Int64.max : kind == 2 ? invalidNow+1 : invalidNow+20_000_000_000
            let bogusReceipt: Double? = kind == 3 ? .nan : nil
            #expect(feed(impossible, now: invalidNow, receipt: bogusReceipt) == .retired)
            #expect(calls.last == "retire:false")
            let before = calls.count
            #expect(feed(base+96_000_000, now: base+96_000_000, down: true) == .waiting)
            #expect(calls.count == before)
            #expect(feed(base+128_000_000, now: base+128_000_000) == .waiting)
            #expect(feed(base+160_000_000, now: base+160_000_000, down: true) == .anchored)
            #expect(Array(calls.dropFirst(before)) == ["retire:true", "begin"])
        }
    }
}

@Test(arguments: [RecoveryClutch.Surface.trackpad, .magicMouse])
func relativeValidButExpiredAcquisitionStillConsumesReplayWatermark(surface: NativeHelperRelativeClutch.Surface) {
    let monitor = UUID(), registration = UUID()
    var session = RecoverySession(source: surface, monitor: monitor, registration: registration,
        afterSequence: 0, afterAcquisitionNS: 0, maximumAgeNS: 150_000_000,
        lanes: [.x: .init(reference: 8192, upper: 16383)])!
    var sequence: UInt64 = 0
    func feed(_ acquired: Int64, now: Int64) -> RecoverySession.Result {
        sequence += 1
        return session.receive(.init(surface: surface, rawDownCount: 0, sourceConsistent: true,
            contacts: [], receipt: Double(acquired)/1e9, nativeRegistration: registration, acquisitionNS: acquired),
            monitor: monitor, sequence: sequence, nowNS: now, permits: { true }, activeLeaseValid: { true },
            begin: { true }, move: { _ in true }, retire: { _ in true })
    }
    let base: Int64 = 1_000_000_000
    #expect(feed(base, now: base+150_000_000) == .retired)
    #expect(feed(base, now: base+150_000_000) == .retired)
    #expect(feed(base+160_000_000, now: base+160_000_000) == .waiting)
}

@Test(arguments: [RecoveryClutch.Surface.trackpad, .magicMouse], [Int64(10_000_000_000), Int64.max])
func relativeBindingRecoversFromImpossibleAcquisitionWithoutAcceptingHeldContact(surface: NativeHelperRelativeClutch.Surface, future: Int64) {
    let monitor = UUID(), registration = UUID()
    let boundary = NativeHelperRelativeArmBoundary(source: surface, registration: registration,
        afterSequence: 0, afterAcquisitionNS: 0)!
    let config = NativeHelperRelativeSingleChannel(settings: .init(), enabled: [.x],
        channel: 2, vibratoCC: 74, expressionCC: 11)!
    var binding = NativeHelperRelativeInputBinding(boundary: boundary, monitor: monitor,
        configuration: config, orientation: .horizontal)!
    var sequence: UInt64 = 0, calls: [String] = []
    func feed(_ acquired: Int64, _ now: Int64, down: Bool = false) -> NativeHelperRelativeInputBinding.Result {
        sequence += 1
        let contacts: [RecoveryClutch.Contact] = down ? [.init(surface: surface, id: 1, x: 0.5, y: 0.5, contactSize: 0.5)] : []
        let frame = RecoveryClutch.SourceFrame(surface: surface, rawDownCount: contacts.count,
            sourceConsistent: true, contacts: contacts, receipt: Double(acquired)/1e9,
            nativeRegistration: registration, acquisitionNS: acquired)
        return binding.receive(frame, source: surface, monitor: monitor, sequence: sequence,
            clock: { now }, live: { true }, activeLeaseValid: { true }, begin: { _, permit in
                guard permit() else { return false }; calls.append("begin"); return true
            }, move: { _, permit in
                guard permit() else { return false }; calls.append("move"); return true
            }, retire: { neutral, _ in calls.append("retire:\(neutral)"); return true })
    }
    let base: Int64 = 1_000_000_000
    #expect(feed(base, base) == .waiting)
    #expect(feed(base+32_000_000, base+32_000_000, down: true) == .anchored)
    #expect(feed(future, base+64_000_000) == .retired)
    #expect(feed(base+96_000_000, base+96_000_000, down: true) == .waiting)
    #expect(feed(base+128_000_000, base+128_000_000) == .waiting)
    #expect(feed(base+160_000_000, base+160_000_000, down: true) == .anchored)
    #expect(calls == ["retire:true", "begin", "retire:false", "retire:true", "begin"])
}
