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


@Test func layoutEditingPreservesDormantLabelsAndUnchangedXYFallback() throws {
    let x = SensorMapping(id:"x",source:.phone,signal:.x,destination:.init(.controlChange,number:74))
    let y = SensorMapping(id:"y",source:.phone,signal:.y,destination:.init(.controlChange,number:71))
    let pad = SensorMapping(id:"pad",source:.phone,signal:.drumPad1,destination:.init(.note,number:36))
    let xy = PerformanceWidget(source:.phone,signal:.x,kind:.xy,label:"Filter",wide:true)
    let drum = PerformanceWidget(source:.phone,signal:.drumPad1,kind:.key,label:"Kick")
    let saved = PerformanceLayout(widgets:[xy,drum])
    let visible = saved.resolved(for:[x])
    #expect(visible.count == 1 && visible.first?.kind == .slider && visible.first?.label == "Filter")
    let edited = try saved.applyingVisibleEdits(visible,for:[x])
    #expect(edited == saved)
    #expect(edited.resolved(for:[x,y,pad]) == [xy,drum])
    var changed = visible
    changed[0].label = "New single axis"
    let replacement = try saved.applyingVisibleEdits(changed,for:[x])
    #expect(replacement.widgets == [changed[0],drum])
    let reset = try saved.applyingVisibleEdits(PerformanceLayout.defaults(for:[x]).widgets,for:[x],preserveDormant:false)
    #expect(reset.widgets.count == 1 && reset.widgets.first?.label == "")
}

@Test func layoutEditingPreservesKeyStyleUntilFallbackIsEdited() throws {
    let note = SensorMapping(id:"n",source:.trackpad,signal:.contact,destination:.init(.note,number:60))
    let cc = SensorMapping(id:"cc",source:.trackpad,signal:.contact,destination:.init(.controlChange,number:74))
    let key = PerformanceWidget(source:.trackpad,signal:.contact,kind:.key,label:"Chord")
    let saved = PerformanceLayout(widgets:[key])
    let fallback = saved.resolved(for:[cc])
    #expect(fallback.first?.kind == .slider)
    let retained = try saved.applyingVisibleEdits(fallback,for:[cc])
    #expect(retained.resolved(for:[note]) == [key])
    var edited = fallback
    edited[0].kind = .knob
    #expect(try saved.applyingVisibleEdits(edited,for:[cc]).widgets == edited)
}


@Test func layoutEditingRetainsXYWhenOnlyYRemainsMapped() throws {
    let x = SensorMapping(id:"x",source:.phone,signal:.x,destination:.init(.controlChange,number:74))
    let y = SensorMapping(id:"y",source:.phone,signal:.y,destination:.init(.controlChange,number:71))
    let xy = PerformanceWidget(source:.phone,signal:.x,kind:.xy,label:"Paired axes")
    let saved = PerformanceLayout(widgets:[xy])
    let visible = saved.resolved(for:[y])
    #expect(visible.count == 1 && visible.first?.signal == .y && visible.first?.label == "")
    let retained = try saved.applyingVisibleEdits(visible,for:[y])
    #expect(retained == saved)
    #expect(retained.resolved(for:[x,y]) == [xy])
}
