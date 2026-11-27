import Testing
@testable import NoSpeakerCore

@Test func customPadPresetsAreValidEditableStandardMIDIDraftsOnAllSurfaces() throws {
    for surface in CustomSurfacePadLayout.Surface.allCases {
        for preset in CustomSurfacePadPreset.allCases {
            let layout = try #require(preset.layout(surface:surface,channel:3))
            let plan = try CustomSurfaceMixedPlan(layout:layout,melodicChannel:3)
            #expect(layout.surface == surface && !plan.destinations.isEmpty)
            #expect(plan.destinations.allSatisfy { $0.channel == (preset == .drums ? 9 : 3) })
            #expect(layout.pads.allSatisfy { $0.isValid })
            if surface == .touchBar { #expect(layout.pads.allSatisfy { $0.y == 0 && $0.height == 10000 }) }
        }
    }
}
@Test func customPadPresetControlChannelsAreExplicitAndNeverFollowMelodicEdits() throws {
    let layout=try #require(CustomSurfacePadPreset.xy.layout(surface:.magicMouse,channel:4))
    let plan=try CustomSurfaceMixedPlan(layout:layout,melodicChannel:8)
    #expect(plan.destinations == Set([SensorDestination(.controlChange,channel:4,number:1),
                                    SensorDestination(.controlChange,channel:4,number:11)]))
    #expect(CustomSurfacePadPreset.sustain.layout(surface:.trackpad,channel:-1) == nil)
    #expect(CustomSurfacePadPreset.drums.layout(surface:.trackpad,channel:16) == nil)
}
