import Foundation
import Testing
@testable import NoSpeakerCore

private typealias OrientationClutch = NativeHelperRelativeClutch
private typealias OrientationFrame = OrientationClutch.SourceFrame
private let orientationRegistration = UUID()

private func orientationFrame(_ surface: OrientationClutch.Surface, ns: Int64 = 1_000_000_000,
                              contacts: [OrientationClutch.Contact], rawCount: Int? = nil,
                              consistent: Bool = true) -> OrientationFrame {
    .init(surface: surface, rawDownCount: rawCount ?? contacts.count, sourceConsistent: consistent,
          contacts: contacts, receipt: Double(ns) / 1_000_000_000,
          nativeRegistration: orientationRegistration, acquisitionNS: ns)
}

private func orientationSameEvidence(_ actual: OrientationFrame, _ original: OrientationFrame) {
    #expect(actual.surface == original.surface)
    #expect(actual.rawDownCount == original.rawDownCount)
    #expect(actual.sourceConsistent == original.sourceConsistent)
    #expect(actual.receipt.bitPattern == original.receipt.bitPattern)
    #expect(actual.nativeRegistration == original.nativeRegistration)
    #expect(actual.acquisitionNS == original.acquisitionNS)
    #expect(actual.isComplete == original.isComplete)
    #expect(actual.isGenuineNeutral == original.isGenuineNeutral)
    #expect(actual.contacts.count == original.contacts.count)
    for (a, b) in zip(actual.contacts, original.contacts) {
        #expect(a.surface == b.surface && a.id == b.id)
        #expect(a.contactSize.bitPattern == b.contactSize.bitPattern)
    }
}

@Test func relativeOrientationPreservesSourceEvidenceAndRotatesOnlySelectedMouse() {
    let surfaces: [OrientationClutch.Surface] = [.trackpad, .magicMouse]
    let values: [Double] = [0, 0.125, 0.25, 0.5, 0.75, 0.875, 1]
    for selected in surfaces {
        for source in surfaces {
            for direction in SurfaceOrientation.allCases {
                let adapter = NativeHelperRelativeOrientation(selectedSurface: selected, magicMouseOrientation: direction)
                for x in values {
                    for y in values {
                        for size in values {
                            let input = orientationFrame(source, contacts: [.init(surface: source, id: 17, x: x, y: y, contactSize: size)])
                            let output = adapter.project(input)
                            orientationSameEvidence(output, input)
                            let rotate = selected == .magicMouse && source == .magicMouse && direction == .vertical
                            #expect(output.contacts.first?.x == (rotate ? y : x))
                            #expect(output.contacts.first?.y == (rotate ? 1 - x : y))
                        }
                    }
                }
                let empty = orientationFrame(source, contacts: [])
                orientationSameEvidence(adapter.project(empty), empty)
            }
        }
    }
}

@Test func relativeOrientationNeverRepairsInvalidContactOrEnvelope() {
    let surface = OrientationClutch.Surface.magicMouse
    let adapter = NativeHelperRelativeOrientation(selectedSurface: surface, magicMouseOrientation: .vertical)
    let invalid: [Double] = [-1, 1.01, .nan, .infinity, -.infinity]
    for value in invalid {
        for axis in OrientationClutch.Axis.allCases {
            let c = OrientationClutch.Contact(surface: surface, id: 1, x: axis == .x ? value : 0.25,
                                              y: axis == .y ? value : 0.5, contactSize: axis == .contactSize ? value : 0.75)
            let input = orientationFrame(surface, contacts: [c])
            let output = adapter.project(input)
            #expect(!output.isComplete)
            orientationSameEvidence(output, input)
            #expect(output.contacts.first?.x.bitPattern == c.x.bitPattern)
            #expect(output.contacts.first?.y.bitPattern == c.y.bitPattern)
        }
    }
    let valid = OrientationClutch.Contact(surface: surface, id: 1, x: 0.25, y: 0.5, contactSize: 0.75)
    let wrong = OrientationClutch.Contact(surface: .trackpad, id: 1, x: 0.25, y: 0.5, contactSize: 0.75)
    let badID = OrientationClutch.Contact(surface: surface, id: -1, x: 0.25, y: 0.5, contactSize: 0.75)
    for input in [orientationFrame(surface, contacts: [valid], rawCount: 0),
                  orientationFrame(surface, contacts: [], rawCount: 1),
                  orientationFrame(surface, contacts: [], consistent: false),
                  orientationFrame(surface, contacts: [valid], consistent: false),
                  orientationFrame(surface, contacts: [wrong]), orientationFrame(surface, contacts: [badID])] {
        let output = adapter.project(input)
        #expect(!output.isComplete && !output.isGenuineNeutral)
        orientationSameEvidence(output, input)
        #expect(output.contacts.first?.x == input.contacts.first?.x)
        #expect(output.contacts.first?.y == input.contacts.first?.y)
    }
    let lift = NativeHelperRelativeEnvelope.project(surface: surface, registration: orientationRegistration, registrationCurrent: true,
        acquisitionNS: 1_000_000_000, validEnvelope: true, rawCount: 1, rawStates: [5],
        records: [.init(state: 5, isDown: false, contact: valid)], maximumRecords: 32)
    #expect(!lift.isGenuineNeutral)
    orientationSameEvidence(adapter.project(lift), lift)
    let duplicate = NativeHelperRelativeEnvelope.project(surface: surface, registration: orientationRegistration, registrationCurrent: true,
        acquisitionNS: 1_000_000_000, validEnvelope: true, rawCount: 2, rawStates: [3, 5],
        records: [.init(state: 3, isDown: true, contact: valid), .init(state: 5, isDown: false, contact: valid)], maximumRecords: 32)
    #expect(!duplicate.isComplete)
    orientationSameEvidence(adapter.project(duplicate), duplicate)
}

@Test func relativeOrientationSessionMovesAndRetiresWithoutFabricatedNeutral() throws {
    let surface = OrientationClutch.Surface.magicMouse
    let adapter = NativeHelperRelativeOrientation(selectedSurface: surface, magicMouseOrientation: .vertical)
    let monitor = UUID()
    var session = try #require(NativeHelperRelativeSession(source: surface, monitor: monitor, registration: orientationRegistration,
        afterSequence: 0, afterAcquisitionNS: 0, maximumAge: 0.25,
        lanes: [.x: .init(reference: 8192, upper: 16383), .y: .init(reference: 64, upper: 127), .contactSize: .init(reference: 64, upper: 127)]))
    var sequence: UInt64 = 0
    var begins = 0
    var moves: [[OrientationClutch.Axis: Int]] = []
    var retires: [Bool] = []
    func input(_ x: Double?, _ y: Double = 0.5, _ size: Double = 0.5, source: OrientationClutch.Surface = .magicMouse) -> OrientationFrame {
        sequence += 1
        let contacts = x.map { [OrientationClutch.Contact(surface: source, id: 1, x: $0, y: y, contactSize: size)] } ?? []
        return orientationFrame(source, ns: 1_000_000_000 + Int64(sequence) * 10_000_000, contacts: contacts)
    }
    func receive(_ frame: OrientationFrame) -> NativeHelperRelativeSession.Result {
        session.receive(adapter.project(frame), monitor: monitor, sequence: sequence, now: frame.receipt,
            permits: { true }, activeLeaseValid: { true }, begin: { begins += 1; return true },
            move: { moves.append($0); return true }, retire: { retires.append($0); return true })
    }
    #expect(receive(input(nil, source: .trackpad)) == .ignored)
    #expect(receive(input(0.25)) == .waiting)
    #expect(receive(input(nil)) == .waiting)
    #expect(receive(input(0.25)) == .anchored)
    #expect(moves.isEmpty)
    #expect(receive(input(0.5, 0.75, 0.75)) == .accepted)
    #expect(moves.last == [.x: 12288, .y: 32, .contactSize: 96])
    #expect(receive(input(.nan)) == .retired)
    #expect(retires.last == false)
    #expect(receive(input(0.5)) == .waiting)
    #expect(begins == 1 && moves.count == 1)
    #expect(receive(input(nil)) == .waiting)
    #expect(retires.last == true)
    #expect(receive(input(0.5)) == .anchored)
    #expect(begins == 2 && moves.count == 1)
    #expect(session.close(retire: { retires.append($0); return true }) == .retired)
    #expect(receive(input(nil)) == .ignored)
}
