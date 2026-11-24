import Foundation
import Testing
@testable import NoSpeakerCore

@Test func continuousResponseRangeReleaseAndGraphArchiveRoundTrip() throws {
    let target = SensorDestination(.controlChange, number: 4)
    let route = SensorMapping(id: "pedal", source: .trackpad, signal: .x, destination: target,
                              response: .init(minimum: 0.2, maximum: 0.8, release: 0.5))
    let patch = InstrumentPatch(routes: [route])
    #expect(try InstrumentPatch.read(patch.archive()) == patch)
    #expect(try PatchGraph(patch: patch).compile(name: patch.name) == patch)
    var sim = PatchSimulation()
    try sim.start(patch, now: 1)
    let input = PatchSimulation.Input(source: .trackpad, signal: .x)
    let min = sim.send(input, value: 0, now: 1.1)
    let max = sim.send(input, value: 1, now: 1.2)
    #expect(min == [.init(target, value: 25)])
    #expect(max == [.init(target, value: 102)])
    #expect(sim.stop() == [.init(target, value: 64)])
}

@Test func continuousResponseSmoothingUsesTimeAndReleaseBypassesFilter() throws {
    let target = SensorDestination(.controlChange, number: 4)
    let patch = InstrumentPatch(routes: [
        .init(id: "smooth", source: .trackpad, signal: .x, destination: target,
              response: .init(smoothingMS: 100, release: 0.25))
    ])
    var sim = PatchSimulation()
    try sim.start(patch, now: 1)
    let input = PatchSimulation.Input(source: .trackpad, signal: .x)
    let first = sim.send(input, value: 0, now: 1)
    #expect(first == [.init(target, value: 0)])
    let halfway = sim.send(input, value: 1, now: 1.1)
    #expect(halfway == [.init(target, value: 80)])
    let next = sim.send(input, value: 1, now: 1.2)
    #expect(next == [.init(target, value: 110)])
    #expect(sim.disconnect(.trackpad) == [.init(target, value: 32)])
}

@Test func customReleaseLedgerRetriesExactValueAndCannotChangePolicyWhileOutstanding() throws {
    let target = SensorDestination(.controlChange, number: 4)
    let patch = InstrumentPatch(routes: [
        .init(id: "release", source: .trackpad, signal: .x, destination: target, response: .init(release: 0.5))
    ])
    var ledger = PatchOutputLedger()
    try ledger.configure(patch)
    let delivered = ledger.deliver(.init(target, value: 120), send: { _ in true })
    #expect(delivered)
    #expect(throws: WorkspaceArchiveError.invalidPayload) { try ledger.configure(.starter) }
    var attempts: [SensorCommand] = []
    let failed = ledger.releaseAll(send: { attempts.append($0); return false })
    #expect(!failed)
    let retry = ledger.releaseAll(send: { attempts.append($0); return true })
    #expect(retry && ledger.outstanding.isEmpty)
    #expect(attempts == [.init(target, value: 64),.init(target, value: 64)])
}

@Test func continuousResponseRejectsConflictingReleaseAndGateModification() throws {
    let target = SensorDestination(.controlChange, number: 4)
    let a = SensorMapping(id: "a", source: .trackpad, signal: .x, destination: target, response: .init(release: 0.5))
    var b = SensorMapping(id: "b", source: .phone, signal: .x, destination: target)
    var router = SensorRouter()
    #expect(!InstrumentPatch(routes: [a,b]).isValid)
    #expect(throws: SensorRouterError.invalidMappings) { try router.configure([a,b]) }
    b.response = .init(release: 0.5)
    try router.configure([a,b])
    b.destination = .init(.note, number: 60)
    #expect(!b.isValid)
    #expect(!ContinuousResponse(minimum: 0.9, maximum: 0.2).isValid)
}

@Test func legacyPatchWithoutResponseDecodesAndNewPanReturnsCenter() throws {
    let json = """
    {"id":"old","source":"trackpad","signal":"x","destination":{"kind":"controlChange","channel":0,"number":74},"calibration":{"minimum":0,"maximum":1,"inverted":false,"deadZone":0,"exponent":1},"priority":0,"threshold":0.55,"hysteresis":0.08,"velocity":100}
    """
    let old = try JSONDecoder().decode(SensorMapping.self, from: Data(json.utf8))
    #expect(old.response == nil && old.isValid)
    let pan = try ExpressivePreset.pan.appending(to: .init(), source: .trackpad, signal: .x, channel: 0)
    #expect(pan.routes.first?.response?.releaseValue(for: .init(.controlChange, number: 10)) == 64)
}
