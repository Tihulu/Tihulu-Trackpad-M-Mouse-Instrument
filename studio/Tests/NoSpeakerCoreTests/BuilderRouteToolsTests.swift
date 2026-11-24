import Testing
@testable import NoSpeakerCore

@Test func builderPresetAppendPreservesCustomRoutesLayoutAndSource() throws {
    let custom = SensorMapping(id:"custom",source:.phone,signal:.pianoKey0,destination:.init(.note,channel:3,number:70))
    let patch = InstrumentPatch(routes:[custom],performanceLayout:.init(widgets:[.init(source:.phone,signal:.pianoKey0,label:"Custom key")]))
    let preset = BuilderRouteTools.MobilePreset.piano
    #expect(preset.missingCount(in:patch,source:.phone) == 25)
    let next = try preset.appending(to:patch,source:.phone)
    #expect(next.routes.count == 26 && next.routes.first == custom)
    #expect(next.performanceLayout == patch.performanceLayout)
    #expect(try preset.appending(to:next,source:.phone) == next)
    #expect(preset.missingCount(in:next,source:.tablet) == 26)
    #expect(try preset.appending(to:next,source:.tablet).routes.count == 52)
}
@Test func builderPresetRejectsOverflowAndInvalidSourceAtomically() throws {
    let routes = (0..<60).map { i in SensorMapping(id:"route-\(i)",source:.trackpad,signal:.contact,destination:.init(.note,number:i)) }
    let patch = InstrumentPatch(routes:routes)
    #expect(throws:SensorRouterError.invalidMappings) { try BuilderRouteTools.MobilePreset.pedals.appending(to:patch,source:.phone) }
    #expect(throws:SensorRouterError.invalidMappings) { try BuilderRouteTools.MobilePreset.drums.appending(to:patch,source:.camera) }
    #expect(patch.routes == routes)
}
@Test func builderFilterUsesSourceTargetsAndLabelsWithoutReordering() {
    let patch = InstrumentPatch(routes:[
        .init(id:"a",source:.phone,signal:.x,destination:.init(.controlChange,channel:1,number:74)),
        .init(id:"b",source:.tablet,signal:.x,destination:.init(.controlChange,channel:1,number:74)),
        .init(id:"c",source:.phone,signal:.contact,destination:.init(.note,number:60))
    ],performanceLayout:.init(widgets:[.init(source:.phone,signal:.x,label:"Guitar filter")]))
    #expect(BuilderRouteTools.visibleIDs(in:patch,source:nil,query:"cc 74") == ["a","b"])
    #expect(BuilderRouteTools.visibleIDs(in:patch,source:.phone,query:"GUITAR Ch 2") == ["a"])
    #expect(BuilderRouteTools.visibleIDs(in:patch,source:.tablet,query:"guitar").isEmpty)
    #expect(BuilderRouteTools.visibleIDs(in:patch,source:nil,query:"  ") == ["a","b","c"])
}
