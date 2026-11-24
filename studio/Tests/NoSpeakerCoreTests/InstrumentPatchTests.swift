import Foundation
import Testing
@testable import NoSpeakerCore

@Test func instrumentPatchArchiveRejectsUnsafeAndDuplicateRoutes() throws {
    var patch = InstrumentPatch.starter
    #expect(patch.isValid)
    let data = try patch.archive()
    #expect(try InstrumentPatch.read(data) == patch)
    patch.routes.append(patch.routes[0])
    #expect(!patch.isValid)
    patch = .starter
    patch.routes[0].destination = .init(.controlChange, number: 101)
    #expect(!patch.isValid)
    #expect(throws: WorkspaceArchiveError.invalidPayload) { try patch.archive() }
}

@Test func patchSimulationCombinesSourcesAndReleasesScopedOwnership() throws {
    let key = SensorDestination(.note, number: 60)
    let patch = InstrumentPatch(routes: [
        .init(id: "A", source: .trackpad, signal: .contact, destination: key),
        .init(id: "B", source: .magicMouse, signal: .contact, destination: key)
    ])
    var simulation = PatchSimulation()
    try simulation.start(patch, now: 1)
    #expect(simulation.inputs.count == 2)
    let a = PatchSimulation.Input(source: .trackpad, signal: .contact)
    let b = PatchSimulation.Input(source: .magicMouse, signal: .contact)
    let on = simulation.send(a, value: 1, now: 1.1)
    #expect(on == [.init(key, value: 100)])
    let joined = simulation.send(b, value: 1, now: 1.2)
    #expect(joined.isEmpty)
    let first = simulation.disconnect(.trackpad)
    #expect(first.isEmpty)
    let stop = simulation.stop()
    #expect(stop == [.init(key, value: 0)])
    #expect(!simulation.running)
}

@Test func patchLedgerRestoresContinuousAndNotesAfterFailedDelivery() {
    var ledger = PatchOutputLedger()
    let bend = SensorDestination(.pitchBend)
    let note = SensorDestination(.note, number: 60)
    let on = ledger.deliver(.init(note, value: 100), send: { _ in true })
    let failed = ledger.deliver(.init(bend, value: 9000), send: { _ in false })
    #expect(on && !failed)
    #expect(ledger.outstanding.count == 2)
    var sent: [SensorCommand] = []
    let released = ledger.releaseAll(send: { sent.append($0); return $0.destination != bend })
    #expect(!released)
    #expect(sent == [.init(note, value: 0), .init(bend, value: 8192)])
    #expect(ledger.outstanding == [bend])
    let retry = ledger.releaseAll(send: { _ in true })
    #expect(retry && ledger.outstanding.isEmpty)
}
