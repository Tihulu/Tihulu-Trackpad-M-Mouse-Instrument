import Testing
@testable import NoSpeakerCore

@Test func patchGraphRoundTripPreservesRoutesAndSharesIdenticalNodes() throws {
    var patch = InstrumentPatch.starter
    patch.routes.append(.init(id: "second", source: .trackpad, signal: .contact,
                              destination: .init(.note, number: 64), threshold: 0.7))
    let graph = PatchGraph(patch: patch)
    #expect(graph.inputs.count == 3)
    #expect(graph.processors.count == 3)
    #expect(graph.outputs.count == 4)
    #expect(try graph.compile(name: patch.name) == patch)
}

@Test func patchGraphFanoutRunsThroughExistingRouter() throws {
    var graph = PatchGraph()
    graph.inputs = [.init(id: "input", source: .trackpad, signal: .contact)]
    graph.processors = [.init(id: "processor", inputID: "input")]
    graph.outputs = [
        .init(id: "a", processorID: "processor", destination: .init(.note, number: 60)),
        .init(id: "b", processorID: "processor", destination: .init(.note, number: 64))
    ]
    let patch = try graph.compile(name: "Fanout")
    var simulation = PatchSimulation()
    try simulation.start(patch, now: 1)
    let commands = simulation.send(.init(source: .trackpad, signal: .contact), value: 1, now: 1.1)
    #expect(Set(commands.map(\.destination.number)) == [60,64])
    #expect(commands.allSatisfy { $0.value == 100 })
    let released = simulation.stop()
    #expect(released.count == 2 && released.allSatisfy { $0.value == 0 })
}

@Test func patchGraphRejectsDanglingDuplicateAndReservedCC() throws {
    var graph = PatchGraph(patch: .starter)
    let first = try #require(graph.inputs.first)
    graph.removeInput(first.id)
    #expect(throws: PatchGraphError.missingConnection) { try graph.compile(name: "Broken") }
    graph = PatchGraph(patch: .starter)
    graph.outputs[0].id = graph.inputs[0].id
    #expect(throws: PatchGraphError.duplicateID) { try graph.compile(name: "Duplicate") }
    graph = PatchGraph(patch: .starter)
    graph.outputs[0].destination = .init(.controlChange, number: 101)
    #expect(throws: PatchGraphError.invalidNode) { try graph.compile(name: "Reserved") }
    graph = PatchGraph(patch: .starter)
    graph.removeProcessor(graph.processors[0].id)
    #expect(throws: PatchGraphError.missingConnection) { try graph.compile(name: "Disconnected") }
}
