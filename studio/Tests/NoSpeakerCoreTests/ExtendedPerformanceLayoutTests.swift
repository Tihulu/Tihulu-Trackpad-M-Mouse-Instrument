import Testing
@testable import NoSpeakerCore

@Test func heldNoteWidgetSupportsChordAndInvertedGate() throws {
    let widget = PerformanceWidget(source: .trackpad, signal: .contact, kind: .key, label: "Chord")
    let routes = [60,64,67].map {
        SensorMapping(id: "note-\($0)", source: .trackpad, signal: .contact,
                      destination: .init(.note, number: $0), calibration: .init(inverted: true))
    }
    let press = try #require(widget.keyPressValue(for: routes))
    #expect(press == 0)
    var sim = PatchSimulation()
    try sim.start(.init(routes: routes), now: 1)
    let commands = sim.send(widget.inputs[0], value: press, now: 1.1)
    #expect(Set(commands.map(\.destination.number)) == [60,64,67])
    #expect(commands.allSatisfy { $0.value == 100 })
    let off = sim.release(widget.inputs[0])
    #expect(off.count == 3 && off.allSatisfy { $0.value == 0 })
}

@Test func heldNoteWidgetFallsBackForIncompatibleRoutes() {
    let key = PerformanceWidget(source: .trackpad, signal: .contact, kind: .key)
    let note = SensorMapping(id: "note", source: .trackpad, signal: .contact, destination: .init(.note, number: 60))
    let control = SensorMapping(id: "cc", source: .trackpad, signal: .contact, destination: .init(.controlChange, number: 4))
    #expect(key.keyPressValue(for: [note,control]) == nil)
    #expect(PerformanceLayout(widgets: [key]).resolved(for: [note,control]).first?.kind == .slider)
    var inverted = note
    inverted.id = "inverted"
    inverted.calibration.inverted = true
    #expect(key.keyPressValue(for: [note,inverted]) == nil)
}

@Test func extendedLayoutKindsSurviveArchiveAndGraph() throws {
    let routes = InstrumentPatch.starter.routes
    let layout = PerformanceLayout(widgets: [
        .init(source: .trackpad, signal: .contact, kind: .key),
        .init(source: .trackpad, signal: .x, kind: .ribbon),
        .init(source: .magicMouse, signal: .y, kind: .knob)
    ])
    let patch = InstrumentPatch(routes: routes, performanceLayout: layout)
    #expect(patch.isValid)
    #expect(try InstrumentPatch.read(patch.archive()) == patch)
    #expect(try PatchGraph(patch: patch).compile(name: patch.name) == patch)
    #expect(layout.resolved(for: routes) == layout.widgets)
}


@Test func tapPadUsesInvertedGateAndRejectsIncompatibleGateFanout() throws {
    let pad = PerformanceWidget(source:.trackpad,signal:.contact,kind:.pad)
    let note = SensorDestination(.note,number:60)
    let inverted = SensorMapping(id:"inverted",source:.trackpad,signal:.contact,destination:note,calibration:.init(inverted:true))
    let sustain = SensorMapping(id:"sustain",source:.trackpad,signal:.contact,destination:.init(.sustain),calibration:.init(inverted:true))
    let value = try #require(pad.pulseValue(for:[inverted,sustain]))
    #expect(value == 0)
    var sim = PatchSimulation()
    try sim.start(.init(routes:[inverted,sustain]),now:1)
    let on = sim.send(pad.inputs[0],value:value,now:1.1)
    #expect(on.contains(.init(note,value:100)))
    #expect(on.contains(.init(.init(.sustain),value:127)))
    let off = sim.release(pad.inputs[0])
    #expect(off.count == 2 && off.allSatisfy { $0.value == 0 })
    let opposite = SensorMapping(id:"opposite",source:.trackpad,signal:.contact,destination:.init(.note,number:64))
    #expect(pad.pulseValue(for:[inverted,opposite]) == nil)
    let cc = SensorMapping(id:"cc",source:.trackpad,signal:.contact,destination:.init(.controlChange,number:74))
    #expect(pad.pulseValue(for:[cc]) == 1)
    #expect(pad.pulseValue(for:[]) == nil)
}
