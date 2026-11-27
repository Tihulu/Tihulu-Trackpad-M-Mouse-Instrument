import Foundation
import Testing
@testable import NoSpeakerCore

private typealias Clutch = NativeHelperRelativeClutch
private typealias Boundary = NativeHelperRelativeArmBoundary
private typealias Fence = NativeHelperRelativeAcquisitionFence

private func sample(_ ns: Int64?, registration: UUID?, surface: Clutch.Surface = .trackpad,
                    x: Double? = nil, consistent: Bool = true, receipt: Double? = nil) -> Clutch.SourceFrame {
    let contacts: [Clutch.Contact] = x.map { [.init(surface: surface, id: 1, x: $0, y: 0.5, contactSize: 0.5)] } ?? []
    return .init(surface: surface, rawDownCount: contacts.count, sourceConsistent: consistent,
                 contacts: contacts, receipt: receipt ?? ns.map { Double($0) / 1_000_000_000 } ?? .nan,
                 nativeRegistration: registration, acquisitionNS: ns)
}

@Test func relativeAcquisitionFenceRejectsMissingMalformedOrPreArmEvidence() throws {
    let registration = UUID()
    let boundary = try #require(Boundary(source: .trackpad, registration: registration,
                                         afterSequence: 10, afterAcquisitionNS: 1_000_000_000))
    #expect(Boundary(source: .trackpad, registration: registration, afterSequence: 10, afterAcquisitionNS: -1) == nil)
    #expect(Boundary(source: .trackpad, registration: registration, afterSequence: 10, afterAcquisitionNS: .max) == nil)
    #expect(Boundary(source: .trackpad, registration: registration, afterSequence: .max, afterAcquisitionNS: 1) == nil)
    let invalid: [(Clutch.SourceFrame, UInt64)] = [
        (sample(nil, registration: registration), 11),
        (sample(-1, registration: registration), 11),
        (sample(999_999_999, registration: registration), 11),
        (sample(1_000_000_000, registration: registration), 11),
        (sample(1_000_000_001, registration: registration), 10),
        (sample(1_000_000_001, registration: registration), 9),
        (sample(1_000_000_001, registration: nil), 11),
        (sample(1_000_000_001, registration: UUID()), 11),
        (sample(1_000_000_001, registration: registration, surface: .magicMouse), 11),
        (sample(1_000_000_001, registration: registration, consistent: false), 11),
        (sample(1_000_000_001, registration: registration, x: .nan), 11),
        (sample(1_000_000_001, registration: registration, receipt: 1.1), 11),
        (sample(.max, registration: registration), 11)
    ]
    for (frame, sequence) in invalid {
        var fence = boundary.fence(for: frame, sequence: sequence)
        #expect(fence.rejected)
        let admitted = fence.permits(nowNS: 1_000_000_002, live: true)
        #expect(!admitted)
    }
    var accepted = boundary.fence(for: sample(1_000_000_001, registration: registration), sequence: 11)
    let admitted = accepted.permits(nowNS: 1_000_000_001, live: true)
    #expect(admitted)
}

@Test func relativeAcquisitionFenceEnforcesExactExistingDeadlineAcrossUptimes() throws {
    #expect(Fence.maximumAgeNS == 150_000_000)
    #expect(Double(Fence.maximumAgeNS) / 1_000_000_000 == TouchPublicationAdmission.maximumAge)
    let registration = UUID()
    for source in [Clutch.Surface.trackpad, .magicMouse] {
        for acquired: Int64 in [1, 1_000_000_000, 1_000_000_000_000_000, 100_000_000_000_000_000, .max - 150_000_001] {
            let boundary = try #require(Boundary(source: source, registration: registration,
                                                 afterSequence: 4, afterAcquisitionNS: acquired - 1))
            let frame = sample(acquired, registration: registration, surface: source)
            for offset: Int64 in [0, 1, 149_999_998, 149_999_999, 150_000_000, 150_000_001] {
                var fence = boundary.fence(for: frame, sequence: 5)
                let admitted = fence.permits(nowNS: acquired + offset, live: true)
                #expect(admitted == (offset < Fence.maximumAgeNS))
                #expect(fence.rejected == !admitted)
                if !admitted {
                    let replay = fence.permits(nowNS: acquired, live: true)
                    #expect(!replay)
                }
            }
        }
    }
}

@Test func relativeAcquisitionFenceNeverRecoversAfterClockRegressionOrLiveLoss() throws {
    let registration = UUID(), acquired: Int64 = 1_000_000_000
    let boundary = try #require(Boundary(source: .trackpad, registration: registration,
                                         afterSequence: 1, afterAcquisitionNS: acquired - 1))
    let frame = sample(acquired, registration: registration)
    for (now, live) in [(acquired - 1, true), (-1, true), (Int64.max, true),
                        (acquired + 99, true), (acquired + 100, false), (acquired + 150_000_000, true)] {
        var fence = boundary.fence(for: frame, sequence: 2)
        let first = fence.permits(nowNS: acquired + 100, live: true)
        let repeated = fence.permits(nowNS: acquired + 100, live: true)
        let denied = fence.permits(nowNS: now, live: live)
        #expect(first && repeated && !denied && fence.rejected)
        let replay = fence.permits(nowNS: acquired + 101, live: true)
        #expect(!replay)
    }
}

@Test func relativeAcquisitionFenceStopsLateSendEvenWhileQueueReceiptIsFresh() throws {
    let registration = UUID(), monitor = UUID()
    let boundary = try #require(Boundary(source: .trackpad, registration: registration,
                                         afterSequence: 1, afterAcquisitionNS: 999_999_999))
    var session = try #require(NativeHelperRelativeSession(source: boundary.source, monitor: monitor,
        registration: boundary.registration, afterSequence: boundary.afterSequence,
        afterAcquisitionNS: boundary.afterAcquisitionNS, maximumAge: TouchPublicationAdmission.maximumAge,
        lanes: [.x: .init(reference: 8192, upper: 16383)]))
    var releases: [Bool] = [], sent = 0
    for (seq, acquired, x): (UInt64, Int64, Double?) in [(2, 1_000_000_000, nil), (3, 1_010_000_000, 0.5)] {
        let frame = sample(acquired, registration: registration, x: x)
        var fence = boundary.fence(for: frame, sequence: seq)
        let result = session.receive(frame, monitor: monitor, sequence: seq, now: frame.receipt,
            permits: { fence.permits(nowNS: acquired, live: true) }, activeLeaseValid: { true },
            begin: { true }, move: { _ in sent += 1; return true }, retire: { releases.append($0); return true })
        #expect(result == (x == nil ? .waiting : .anchored))
    }
    let acquired: Int64 = 1_020_000_000
    let frame = sample(acquired, registration: registration, x: 0.75)
    var fence = boundary.fence(for: frame, sequence: 4)
    var nowNS = acquired + 1
    let result = session.receive(frame, monitor: monitor, sequence: 4, now: Double(nowNS) / 1_000_000_000,
        permits: { fence.permits(nowNS: nowNS, live: true) }, activeLeaseValid: { true }, begin: { true },
        move: { _ in
            nowNS = acquired + Fence.maximumAgeNS
            // Simulate synchronous delay before the first physical send.
            #expect(TouchPublicationAdmission.permits(queuedAt: 1.16, now: Double(nowNS) / 1_000_000_000))
            guard fence.permits(nowNS: nowNS, live: true) else { return false }
            sent += 1; return true
        }, retire: { releases.append($0); return true })
    #expect(result == .retired)
    #expect(sent == 0 && releases == [true, false])
    #expect(fence.rejected)
}
