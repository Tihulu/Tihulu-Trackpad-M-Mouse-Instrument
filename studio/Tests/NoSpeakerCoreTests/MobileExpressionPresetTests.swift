import Testing
@testable import NoSpeakerCore

@Test func expressionScalesMapExactDiscreteNotes() throws {
    #expect(MobileExpressionPreset.major.notes(root:48) == [48,50,52,53,55,57,59,60])
    #expect(MobileExpressionPreset.minor.notes(root:60) == [60,62,63,65,67,68,70,72])
    #expect(MobileExpressionPreset.pentatonic.notes(root:115) == [115,117,119,122,124,127])
    #expect(MobileExpressionPreset.chromatic.notes(root:116) == nil)
    #expect(MobileExpressionPreset.major.notes(root:Int.max) == nil)
}

@Test func expressionCustomNotesPreserveOrderAndRejectInvalidValues() {
    #expect(MobileExpressionPreset.custom.notes(root:0,custom:"72, 48, 48, 127, 0") == [72,48,48,127,0])
    for value in ["", "60.5", "128", "-1", "60 x", String(repeating:"60,",count:26),String(repeating:" ",count:257)] {
        #expect(MobileExpressionPreset.custom.notes(root:0,custom:value) == nil)
    }
}

@Test func expressionRoutesPreserveOtherSourcesAndRefuseOverwrite() throws {
    let base = InstrumentPatch.starter
    let next = try MobileExpressionPreset.major.appending(to:base,source:.phone,channel:3,root:48)
    #expect(Array(next.routes.prefix(base.routes.count)) == base.routes)
    let routes = next.routes.filter { $0.source == .phone }
    #expect(routes.count == 9)
    #expect(routes.dropLast().map { $0.destination.number } == [48,50,52,53,55,57,59,60])
    #expect(routes.allSatisfy { $0.destination.channel == 3 })
    #expect(routes.last?.destination.kind == .sustain)
    #expect(next.isValid)
    #expect(throws: SensorRouterError.self) {
        _ = try MobileExpressionPreset.minor.appending(to:next,source:.phone,channel:3,root:48)
    }
    #expect(throws: SensorRouterError.self) {
        _ = try MobileExpressionPreset.major.appending(to:base,source:.camera,channel:3,root:48)
    }
    #expect(throws: SensorRouterError.self) {
        _ = try MobileExpressionPreset.major.appending(to:base,source:.tablet,channel:16,root:48)
    }
}

@Test func expressionRouteCapacityIsAtomic() throws {
    let base = InstrumentPatch(name:"Existing",routes:(0..<60).map {
        SensorMapping(id:"r"+String($0),source:.trackpad,signal:.contact,destination:.init(.note,number:$0))
    })
    #expect(base.isValid)
    #expect(throws: SensorRouterError.self) {
        _ = try MobileExpressionPreset.major.appending(to:base,source:.phone,channel:0,root:48)
    }
    #expect(base.routes.count == 60)
    let result = try MobileExpressionPreset.custom.appending(to:base,source:.phone,channel:0,root:48,custom:"60,62,64")
    #expect(result.routes.count == 64)
    #expect(result.isValid)
}
