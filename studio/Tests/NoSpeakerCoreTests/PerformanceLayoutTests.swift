import Foundation
import Testing
@testable import NoSpeakerCore

@Test func performanceLayoutArchiveAndGraphPreserveCustomControls() throws {
    var patch = InstrumentPatch.starter
    patch.performanceLayout = .init(widgets: [
        .init(source: .trackpad, signal: .contact, kind: .pad, label: "Chord trigger"),
        .init(source: .trackpad, signal: .x, kind: .pedal, label: "Bend", wide: true)
    ])
    #expect(patch.isValid)
    #expect(try InstrumentPatch.read(patch.archive()) == patch)
    #expect(try PatchGraph(patch: patch).compile(name: patch.name) == patch)
    let resolved = try #require(patch.performanceLayout).resolved(for: patch.routes)
    #expect(resolved.count == 3)
    #expect(resolved[0].label == "Chord trigger")
    #expect(resolved[2].source == .magicMouse)
}

@Test func layoutXYRejectsDuplicateAxesAndFallsBackForUnmappedAxis() {
    let x = SensorMapping(id: "x", source: .trackpad, signal: .x, destination: .init(.controlChange, number: 74))
    let y = SensorMapping(id: "y", source: .trackpad, signal: .y, destination: .init(.controlChange, number: 71))
    let xy = PerformanceWidget(source: .trackpad, signal: .x, kind: .xy, label: "Filter")
    var layout = PerformanceLayout(widgets: [xy])
    #expect(layout.isValid)
    #expect(layout.resolved(for: [x,y]) == [xy])
    #expect(layout.resolved(for: [x]).first?.kind == .slider)
    layout.widgets.append(.init(source: .trackpad, signal: .y))
    #expect(!layout.isValid)
}

@Test func scopedWidgetReleaseDoesNotTriggerInvertedGateOrResetSiblingAxis() throws {
    let note = SensorDestination(.note, number: 60)
    let bend = SensorDestination(.pitchBend)
    let patch = InstrumentPatch(routes: [
        .init(id: "note", source: .trackpad, signal: .contact, destination: note, calibration: .init(inverted: true)),
        .init(id: "bend", source: .trackpad, signal: .x, destination: bend)
    ])
    var sim = PatchSimulation()
    try sim.start(patch, now: 1)
    let pad = PatchSimulation.Input(source: .trackpad, signal: .contact)
    let axis = PatchSimulation.Input(source: .trackpad, signal: .x)
    let on = sim.send(pad, value: 0, now: 1.1)
    let moved = sim.send(axis, value: 1, now: 1.2)
    #expect(on == [.init(note, value: 100)])
    #expect(moved == [.init(bend, value: 16383)])
    let released = sim.release(pad)
    #expect(released == [.init(note, value: 0)])
    #expect(sim.release(pad).isEmpty)
    #expect(sim.stop() == [.init(bend, value: 8192)])
}
