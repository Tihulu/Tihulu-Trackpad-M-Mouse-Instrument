import Foundation
import Testing
@testable import NoSpeakerCore

/// Cleanup success is not, by itself, proof of a fresh neutral observation.
@Test(arguments: [NativeHelperRelativeClutch.Surface.trackpad, .magicMouse], [false, true])
func relativeNeutralCleanupMustRemainAdmitted(surface: NativeHelperRelativeClutch.Surface, initiallyActive: Bool) throws {
    typealias Clutch = NativeHelperRelativeClutch
    typealias Binding = NativeHelperRelativeInputBinding
    for fault in 0..<5 {
        for clean in [false, true] {
            for releaseClean in [false, true] {
                let monitor = UUID(), registration = UUID()
                let boundary = try #require(NativeHelperRelativeArmBoundary(source: surface, registration: registration,
                    afterSequence: 0, afterAcquisitionNS: 0))
                let config = try #require(NativeHelperRelativeSingleChannel(settings: .init(), enabled: [.x],
                    channel: 2, vibratoCC: 74, expressionCC: 11))
                var binding = try #require(Binding(boundary: boundary, monitor: monitor, configuration: config, orientation: .horizontal))
                var now: Int64 = 1_000_000_000, sequence: UInt64 = 0
                var clock = now, live = true, inject = false
                var begins = 0, moves = 0, clockReads = 0
                var retirements: [Bool] = []
                func retire(_ neutral: Bool, _: NativeHelperRelativeOutputPlan) -> Bool {
                    retirements.append(neutral)
                    if !inject { return true }
                    if !neutral { return releaseClean }
                    switch fault {
                    case 1: live = false
                    case 2: clock += NativeHelperRelativeAcquisitionFence.maximumAgeNS
                    case 3: clock -= 1
                    case 4: clock = Int64.max
                    default: break
                    }
                    return clean
                }
                func feed(_ x: Double?) -> Binding.Result {
                    now += 10_000_000; sequence += 1; clock = now
                    let contacts: [Clutch.Contact] = x.map { [.init(surface: surface, id: 1, x: $0, y: 0.5, contactSize: 0.5)] } ?? []
                    let frame = Clutch.SourceFrame(surface: surface, rawDownCount: contacts.count, sourceConsistent: true,
                        contacts: contacts, receipt: Double(now)/1e9, nativeRegistration: registration, acquisitionNS: now)
                    return binding.receive(frame, source: surface, monitor: monitor, sequence: sequence,
                        clock: { clockReads += 1; return clock }, live: { live }, activeLeaseValid: { true },
                        begin: { _, permit in guard permit() else { return false }; begins += 1; return true },
                        move: { _, permit in guard permit() else { return false }; moves += 1; return true }, retire: retire)
                }
                if initiallyActive {
                    #expect(feed(nil) == .waiting)
                    #expect(feed(0.5) == .anchored)
                }
                let priorRetirements = retirements.count, priorBegins = begins
                inject = true
                let accepted = fault == 0 && clean
                #expect(feed(nil) == (accepted ? .waiting : .retired))
                #expect(Array(retirements.dropFirst(priorRetirements)) == (accepted ? [true] : [true, false]))
                #expect(begins == priorBegins && moves == 0)
                inject = false; live = true
                // Recover beyond any clock high water reached in cleanup.
                now += NativeHelperRelativeAcquisitionFence.maximumAgeNS
                #expect(feed(0.5) == (accepted ? .anchored : .waiting))
                #expect(begins == priorBegins + (accepted ? 1 : 0))
                if !accepted {
                    #expect(feed(nil) == .waiting)
                    #expect(feed(0.5) == .anchored)
                }
                #expect(feed(0.75) == .accepted)
                #expect(begins == priorBegins + 1 && moves == 1)
                #expect(binding.close(retire: retire) == .retired)
                let finalRetirements = retirements.count, finalBegins = begins
                #expect(feed(nil) == .ignored)
                #expect(feed(0.5) == .ignored)
                #expect(binding.poll(nowNS: now, live: true, activeLeaseValid: { false }, retire: retire) == .ignored)
                #expect(retirements.count == finalRetirements && begins == finalBegins && moves == 1)
                #expect(clockReads > 0)
            }
        }
    }
}
