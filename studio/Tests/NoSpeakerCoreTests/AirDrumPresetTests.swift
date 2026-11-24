import Testing
@testable import NoSpeakerCore

@Test func airDrumPresetsUseUniqueGMNotesAndValidSettings() {
    let routes = AirDrumPreset.allCases.map { $0.route() }
    #expect(Set(routes.map(\.destination.number)).count == routes.count)
    #expect(routes.allSatisfy { $0.destination.channel == 9 && $0.velocity == 127 })
    #expect(AirDrumPreset.snare.note == 38)
    #expect(InstrumentPatch(routes: routes).isValid)
    #expect(AirDrumSensitivity.settings(for: routes)?[.phone]?.threshold == 0.45)
}

@Test func airDrumSensitivitySurvivesArchiveAndPatchGraph() throws {
    var route = AirDrumPreset.kick.route()
    route.threshold = 0.6
    route.hysteresis = 0.3
    route.calibration.exponent = 2
    let patch = InstrumentPatch(routes: [route])
    let decoded = try InstrumentPatch.read(patch.archive())
    let graph = try PatchGraph(patch: decoded).compile(name: patch.name)
    #expect(graph == patch)
    #expect(AirDrumSensitivity.settings(for: graph.routes)?[.phone]?.threshold == 0.6)
}

@Test func airDrumRejectsConflictingSameSourceSettingsButAllowsDifferentSources() {
    let a = AirDrumPreset.kick.route()
    var b = AirDrumPreset.snare.route()
    b.threshold = 0.7
    #expect(!InstrumentPatch(routes: [a,b]).isValid)
    b.source = .tablet
    #expect(InstrumentPatch(routes: [a,b]).isValid)
    b.hysteresis = 0.01
    #expect(!InstrumentPatch(routes: [b]).isValid)
}

@Test func airDrumConfiguredSensitivityChangesOnset() throws {
    var route = AirDrumPreset.snare.route()
    route.threshold = 0.7
    route.hysteresis = 0.4
    let settings = try #require(AirDrumSensitivity.settings(for: route))
    var d = AirStrikeDetector(settings: settings)
    _ = d.ingest(0, now: 1)
    _ = d.ingest(0, now: 1.1)
    let tooSoft = d.ingest(0.6, now: 1.2)
    let hit = d.ingest(0.8, now: 1.25)
    #expect(tooSoft == nil)
    #expect(hit != nil)
}
