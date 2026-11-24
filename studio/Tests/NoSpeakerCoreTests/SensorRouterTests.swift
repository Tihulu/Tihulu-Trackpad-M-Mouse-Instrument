import Foundation
import Testing
@testable import NoSpeakerCore

private func send(_ router: inout SensorRouter, _ id: UUID, _ value: Double,
                  _ seq: UInt64, _ time: Double, signal: SensorSignal = .x) -> [SensorCommand] {
    router.ingest(.init(session: id, signal: signal, value: value,
                        sequence: seq, timestamp: time), now: time)
}

@Test func sharedNotesReleaseOnlyAfterLastOwner() throws {
    let note = SensorDestination(.note, number: 60)
    var router = SensorRouter()
    try router.configure([
        .init(id: "touch", source: .trackpad, signal: .x, destination: note),
        .init(id: "phone", source: .phone, signal: .x, destination: note)
    ])
    let a = try router.connect(.trackpad, now: 1)
    let b = try router.connect(.phone, now: 1)
    #expect(send(&router, a, 0.8, 1, 1) == [.init(note, value: 100)])
    #expect(send(&router, b, 0.9, 1, 1).isEmpty)
    #expect(router.disconnect(a).isEmpty)
    #expect(router.disconnect(b) == [.init(note, value: 0)])
    #expect(router.panic().isEmpty)
}

@Test func priorityControlReturnsToRemainingOwnerAndNeutral() throws {
    let bend = SensorDestination(.pitchBend, channel: 2)
    var router = SensorRouter()
    try router.configure([
        .init(id: "lid", source: .lid, signal: .x, destination: bend),
        .init(id: "phone", source: .phone, signal: .x, destination: bend, priority: 10)
    ])
    let a = try router.connect(.lid, now: 1)
    let b = try router.connect(.phone, now: 1)
    #expect(send(&router, a, 0, 1, 1) == [.init(bend, value: 0)])
    #expect(send(&router, b, 1, 1, 1) == [.init(bend, value: 16383)])
    #expect(send(&router, a, 0.25, 2, 1.1).isEmpty)
    #expect(router.disconnect(b) == [.init(bend, value: 4096)])
    #expect(router.disconnect(a) == [.init(bend, value: 8192)])
}

@Test func sustainUsesHysteresisAndScopedExpiry() throws {
    let sustain = SensorDestination(.sustain)
    var router = SensorRouter()
    try router.configure([
        .init(id: "hold", source: .touchBar, signal: .x, destination: sustain)
    ])
    let a = try router.connect(.touchBar, now: 1)
    let b = try router.connect(.touchBar, now: 1)
    #expect(send(&router, a, 0.6, 1, 1) == [.init(sustain, value: 127)])
    #expect(send(&router, a, 0.5, 2, 1.1).isEmpty)
    #expect(send(&router, b, 0.7, 1, 1.1).isEmpty)
    router.heartbeat(b, now: 3)
    #expect(router.expire(now: 3.2).isEmpty)
    #expect(router.sessionCount == 1)
    #expect(router.expire(now: 5) == [.init(sustain, value: 0)])
    #expect(router.sessionCount == 0)
}

@Test func staleAndInvalidEventsCannotChangeOutput() throws {
    let cc = SensorDestination(.controlChange, number: 74)
    var router = SensorRouter()
    try router.configure([.init(id: "filter", source: .phone, signal: .x, destination: cc)])
    let id = try router.connect(.phone, now: 10)
    #expect(send(&router, id, 1, 1, 10) == [.init(cc, value: 127)])
    #expect(send(&router, id, 0, 1, 10.1).isEmpty)
    #expect(send(&router, id, .nan, 2, 10.1).isEmpty)
    #expect(router.ingest(.init(session: id, signal: .x, value: 0, sequence: 2, timestamp: 10), now: 12).isEmpty)
    #expect(router.disconnect(id) == [.init(cc, value: 0)])
    #expect(send(&router, id, 1, 3, 12).isEmpty)
    let newID = try router.connect(.phone, now: 12)
    #expect(newID != id)
    #expect(send(&router, newID, 1, 1, 12) == [.init(cc, value: 127)])
}

@Test func mappingValidationRejectsReservedCCsAndLiveReplacement() throws {
    var router = SensorRouter()
    let bad = SensorMapping(id: "bad", source: .phone, signal: .x,
                            destination: .init(.controlChange, number: 123))
    #expect(throws: SensorRouterError.invalidMappings) { try router.configure([bad]) }
    let good = SensorMapping(id: "good", source: .phone, signal: .x,
                             destination: .init(.controlChange, number: 11))
    #expect(throws: SensorRouterError.invalidMappings) { try router.configure([good, good]) }
    try router.configure([good])
    _ = try router.connect(.phone, now: 1)
    #expect(throws: SensorRouterError.activeSessions) { try router.configure([]) }
    #expect(router.mappingCount == 1)
}

@Test func calibrationAndSessionLimits() throws {
    let curve = SensorCalibration(minimum: 0.2, maximum: 0.8, inverted: true)
    #expect(curve.apply(0) == 1)
    #expect(curve.apply(1) == 0)
    #expect(abs((curve.apply(0.5) ?? 0) - 0.5) < 0.00001)
    #expect(SensorCalibration(minimum: 0.9, maximum: 0.1).apply(0.5) == nil)
    var router = SensorRouter()
    for _ in 0..<SensorRouter.maxSessions { _ = try router.connect(.phone, now: 1) }
    #expect(throws: SensorRouterError.sessionLimit) { try router.connect(.phone, now: 1) }
    #expect(router.panic().isEmpty)
    #expect(router.sessionCount == 0)
}
