import Foundation
import Testing
@testable import NoSpeakerCore

/// A transient failure must latch for the whole physical observation, even
/// if a later check in the same staged callback sees healthy host state.
@Test(arguments: [NativeHelperRelativeClutch.Surface.trackpad, .magicMouse], [false, true])
func relativeBindingTransientPermitCannotReviveObservation(surface: NativeHelperRelativeClutch.Surface, duringMove: Bool) throws {
    typealias Clutch = NativeHelperRelativeClutch
    typealias Binding = NativeHelperRelativeInputBinding
    for fault in 0..<4 {
        for probes in [1, 2, 5] {
            for clean in [false, true] {
                let monitor = UUID(), registration = UUID()
                let boundary = try #require(NativeHelperRelativeArmBoundary(source: surface, registration: registration,
                    afterSequence: 0, afterAcquisitionNS: 0))
                let config = try #require(NativeHelperRelativeSingleChannel(settings: .init(), enabled: [.x],
                    channel: 2, vibratoCC: 74, expressionCC: 11))
                var binding = try #require(Binding(boundary: boundary, monitor: monitor, configuration: config, orientation: .horizontal))
                var now: Int64 = 1_000_000_000, sequence: UInt64 = 0
                var clock = now, live = true, inject = false, cleanupOK = true
                var checks: [Bool] = [], retirements: [Bool] = []
                var begins = 0, moves = 0, attempted = 0
                func staged(_ permit: () -> Bool) -> Bool {
                    guard permit() else { return false }
                    if !inject { attempted += 1; return true }
                    // The first failure is either transient live loss, exact
                    // deadline, clock regression, or invalid clock sentinel.
                    let original = clock
                    switch fault {
                    case 0: live = false
                    case 1: clock = original + NativeHelperRelativeAcquisitionFence.maximumAgeNS
                    case 2: clock = original - 1
                    default: clock = Int64.max
                    }
                    let denied = permit()
                    checks.append(denied)
                    if denied { attempted += 1 }
                    live = true; clock = original
                    for _ in 0..<probes {
                        let result = permit()
                        checks.append(result)
                        if result { attempted += 1 }
                    }
                    // Deliberately optimistic adapter result: the outer
                    // binding must still reject this observation.
                    return true
                }
                func retire(_ neutral: Bool, _: NativeHelperRelativeOutputPlan) -> Bool {
                    retirements.append(neutral); return cleanupOK
                }
                func feed(_ x: Double?) -> Binding.Result {
                    now += 10_000_000; sequence += 1; clock = now
                    let contacts: [Clutch.Contact] = x.map { [.init(surface: surface, id: 1, x: $0, y: 0.5, contactSize: 0.5)] } ?? []
                    let frame = Clutch.SourceFrame(surface: surface, rawDownCount: contacts.count, sourceConsistent: true,
                        contacts: contacts, receipt: Double(now)/1e9, nativeRegistration: registration, acquisitionNS: now)
                    return binding.receive(frame, source: surface, monitor: monitor, sequence: sequence,
                        clock: { clock }, live: { live }, activeLeaseValid: { true },
                        begin: { _, permit in begins += 1; return staged(permit) },
                        move: { _, permit in moves += 1; return staged(permit) }, retire: retire)
                }
                #expect(feed(nil) == .waiting)
                if duringMove { #expect(feed(0.5) == .anchored) }
                let before = attempted
                inject = true; cleanupOK = clean
                #expect(feed(duringMove ? 0.75 : 0.5) == .retired)
                #expect(checks == Array(repeating: false, count: probes + 1))
                #expect(attempted == before)
                #expect(retirements == [true, false])
                #expect(begins == 1 && moves == (duringMove ? 1 : 0))
                inject = false; cleanupOK = true
                // Move beyond any accepted high-water timestamp from the
                // failed observation, without treating a held finger as lift.
                now += NativeHelperRelativeAcquisitionFence.maximumAgeNS
                #expect(feed(0.75) == .waiting)
                #expect(attempted == before)
                #expect(feed(nil) == .waiting)
                #expect(feed(0.5) == .anchored)
                #expect(feed(0.75) == .accepted)
                #expect(begins == 2 && moves == (duringMove ? 2 : 1))
                #expect(attempted == before + 2)
                #expect(retirements == [true, false, true])
            }
        }
    }
}
