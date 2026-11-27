import Foundation
import Testing
@testable import NoSpeakerCore

struct NativeHelperRelativeEnvelopeMatrixTests {
    private typealias Clutch = NativeHelperRelativeClutch
    private typealias Envelope = NativeHelperRelativeEnvelope

    // Enumerate raw records before filtering. An invalid lift record must
    // never disappear into a valid single touch or zero-record neutral.
    @Test(arguments: [false, true], Array(0...3))
    func rawRecordMatrix(mouse: Bool, count: Int) throws {
        let surface: Clutch.Surface = mouse ? .magicMouse : .trackpad
        let other: Clutch.Surface = mouse ? .trackpad : .magicMouse
        let registration = UUID()
        func frame(_ records: [Envelope.Record], states: [Int], rawCount: Int,
                   current: Bool = true, ns: Int64) -> Clutch.SourceFrame {
            Envelope.project(surface: surface, registration: registration, registrationCurrent: current,
                acquisitionNS: ns, validEnvelope: true, rawCount: rawCount, rawStates: states,
                records: records, maximumRecords: 32)
        }
        let neutral = frame([], states: [], rawCount: 0, ns: 1_000_000_000)
        func held(_ ns: Int64) -> Clutch.SourceFrame {
            let contact = Clutch.Contact(surface: surface, id: 0, x: 0.5, y: 0.5, contactSize: 0.5)
            return frame([.init(state: 3, isDown: true, contact: contact)], states: [3], rawCount: 1, ns: ns)
        }
        let combinations = (0..<count).reduce(1) { result, _ in result * 5 }
        for code in 0..<combinations {
            var digits = code
            let states = (0..<count).map { _ -> Int in
                defer { digits /= 5 }
                return 2 + digits % 5
            }
            for flags in 0..<(1 << count) {
                let down = (0..<count).filter { flags & (1 << $0) != 0 }
                let validStates = states.allSatisfy { [3, 4, 5].contains($0) }
                let correctFlags = down == states.indices.filter { states[$0] == 3 || states[$0] == 4 }
                let expectedBase = validStates && correctFlags && (count == 0 || !down.isEmpty)
                for fault in 0...6 {
                    if ([1, 4, 5].contains(fault) && count == 0) || (fault == 3 && count < 2) { continue }
                    let records = states.enumerated().map { index, state in
                        Envelope.Record(state: state, isDown: down.contains(index), contact: .init(
                            surface: fault == 4 && index == 0 ? other : surface,
                            id: fault == 3 && index == count - 1 ? 0 : index,
                            x: fault == 5 && index == 0 ? .nan : 0.5, y: 0.5, contactSize: 0.5))
                    }
                    var rawStates = states
                    if fault == 1 { rawStates[0] += 1 }
                    let projected = frame(records, states: rawStates, rawCount: count + (fault == 2 ? 1 : 0),
                        current: fault != 6, ns: 2_000_000_000)
                    let valid = expectedBase && fault == 0
                    #expect(projected.isComplete == valid)
                    #expect(projected.isGenuineNeutral == (valid && count == 0))
                    #expect(projected.rawDownCount == down.count)
                    #expect(projected.nativeRegistration == registration && projected.acquisitionNS == 2_000_000_000)
                    var ready = try #require(Clutch(surface: surface, lanes: [.x: .init(reference: 8192, upper: 16383)]))
                    let initial = ready.frame(neutral)
                    #expect(initial == .idle)
                    let result = ready.frame(projected)
                    let expected: Clutch.Result = !valid || down.count > 1 ? .blocked : (count == 0 ? .idle : .anchored)
                    #expect(result == expected)
                    if expected == .blocked {
                        let blocked = ready.frame(held(3_000_000_000))
                        #expect(blocked == .blocked)
                        let lift = ready.frame(frame([], states: [], rawCount: 0, ns: 4_000_000_000))
                        #expect(lift == .idle)
                        let rearm = ready.frame(held(5_000_000_000))
                        #expect(rearm == .anchored)
                    }
                    var active = try #require(Clutch(surface: surface, lanes: [.x: .init(reference: 8192, upper: 16383)]))
                    let activeNeutral = active.frame(neutral)
                    let anchor = active.frame(held(1_500_000_000))
                    #expect(activeNeutral == .idle && anchor == .anchored)
                    let activeResult = active.frame(projected)
                    let sameContact = valid && down == [0]
                    #expect(activeResult == (sameContact ? .idle : .releaseRequired))
                    let continued = active.frame(held(3_000_000_000))
                    let expectedContinued: Clutch.Result = sameContact ? .idle : (valid && count == 0 ? .anchored : .blocked)
                    #expect(continued == expectedContinued)
                }
            }
        }
    }
}
