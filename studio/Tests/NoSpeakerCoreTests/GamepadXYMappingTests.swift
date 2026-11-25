import Testing
@testable import NoSpeakerCore

@Test func xyPresetPreservesButtonsTriggersAndOtherControllers() throws {
    let button = SensorMapping(id:"note",source:.gamepad3,signal:.padA,destination:.init(.note,number:60))
    let pedal = SensorMapping(id:"drive",source:.gamepad3,signal:.padRT,
                              destination:.init(.controlChange,number:80),pedalMode:.toggle)
    let other = SensorMapping(id:"other",source:.gamepad4,signal:.padLSX,destination:.init(.pitchBend,channel:3))
    let base = InstrumentPatch(routes:[button,pedal,other])
    let next = try GamepadXYMapping.installExpression(in:base,source:.gamepad3,channel:2)
    #expect(next.routes.count == 7)
    #expect(Array(next.routes.prefix(3)) == base.routes)
    let axes = next.routes.filter { $0.source == .gamepad3 && GamepadFrame.sticks.contains($0.signal) }
    #expect(Set(axes.map(\.signal)) == Set(GamepadFrame.sticks))
    #expect(axes.allSatisfy { $0.destination.channel == 2 })
    #expect(throws:SensorRouterError.invalidMappings) {
        try GamepadXYMapping.installExpression(in:next,source:.gamepad3,channel:2)
    }
    let edited = try GamepadXYMapping.installExpression(in:next,source:.gamepad3,channel:5,replaceExisting:true)
    #expect(Array(edited.routes.prefix(3)) == base.routes)
    #expect(edited.routes.suffix(4).allSatisfy { $0.destination.channel == 5 })
    #expect(try InstrumentPatch.read(edited.archive()) == edited)
}

@Test func xyAxisEditPreservesMatchingIdentityAndRejectsConflicts() throws {
    let initial = try GamepadXYMapping.installExpression(in:.init(),source:.gamepad1,channel:0)
    let original = try #require(initial.routes.first(where:{ $0.signal == .padRSX }))
    let calibration = SensorCalibration(inverted:true,exponent:2)
    let response = ContinuousResponse(minimum:0.2,maximum:0.8,smoothingMS:50,release:0.5)
    let updated = try GamepadXYMapping.replaceAxis(in:initial,source:.gamepad1,signal:.padRSX,
        target:original.destination,calibration:calibration,response:response)
    let edited = try #require(updated.routes.first(where:{ $0.signal == .padRSX }))
    #expect(edited.id == original.id)
    #expect(edited.calibration == calibration && edited.response == response)
    #expect(updated.routes.filter { $0.signal != .padRSX } == initial.routes.filter { $0.signal != .padRSX })
    #expect(throws:SensorRouterError.invalidMappings) {
        try GamepadXYMapping.replaceAxis(in:initial,source:.gamepad1,signal:.padRSX,
            target:.init(.note,number:60))
    }
    #expect(throws:SensorRouterError.invalidMappings) {
        try GamepadXYMapping.replaceAxis(in:initial,source:.gamepad1,signal:.padRSX,
            target:original.destination,calibration:.init(minimum:0.8,maximum:0.2))
    }
    let conflict = SensorMapping(id:"other",source:.gamepad2,signal:.padRSY,
                                 destination:.init(.controlChange,number:74))
    #expect(throws:SensorRouterError.invalidMappings) {
        try GamepadXYMapping.installExpression(in:.init(routes:[conflict]),source:.gamepad1,channel:0)
    }
}

@Test func xyRuntimeMovesFourAxesTogetherAndReleasesOneWithoutChangingOthers() throws {
    let patch = try GamepadXYMapping.installExpression(in:.init(),source:.gamepad4,channel:3)
    let zero = Array(repeating:0.0,count:12)
    let neutral = try #require(GamepadFrame(buttons:zero,triggers:[0,0],sticks:[0,0,0,0]))
    let all = try #require(GamepadFrame(buttons:zero,triggers:[0,0],sticks:[1,1,-1,-1]))
    let oneCentered = try #require(GamepadFrame(buttons:zero,triggers:[0,0],sticks:[0,1,-1,-1]))
    let bend = SensorDestination(.pitchBend,channel:3)
    let mod = SensorDestination(.controlChange,channel:3,number:1)
    let pan = SensorDestination(.controlChange,channel:3,number:10)
    let filter = SensorDestination(.controlChange,channel:3,number:74)
    var runtime = PhysicalPatchRuntime()
    try runtime.configure(patch)
    _ = runtime.receiveGamepad(source:.gamepad4,frame:neutral,now:1)
    let first = runtime.receiveGamepad(source:.gamepad4,frame:all,now:1.01)
    #expect(first.count == 4)
    #expect(first.contains(.init(bend,value:16383)))
    #expect(first.contains(.init(mod,value:127)))
    #expect(first.contains(.init(pan,value:0)))
    #expect(first.contains(.init(filter,value:0)))
    let partial = runtime.receiveGamepad(source:.gamepad4,frame:oneCentered,now:1.02)
    #expect(partial == [.init(bend,value:8192)])
    let release = runtime.receiveGamepad(source:.gamepad4,frame:neutral,now:1.03)
    #expect(release.count == 3)
    #expect(release.contains(.init(mod,value:0)))
    #expect(release.contains(.init(pan,value:64)))
    #expect(release.contains(.init(filter,value:64)))
    #expect(runtime.stop().isEmpty)
}

@Test func xyPresetFitsFourControllersAndPreservesRouteCapacity() throws {
    var patch = InstrumentPatch()
    for (i,source) in GamepadFrame.orderedSources.enumerated() {
        patch = try GamepadPedalboardPreset.install(in:patch,source:source,channel:i)
        patch = try GamepadXYMapping.installExpression(in:patch,source:source,channel:i,replaceExisting:true)
    }
    #expect(patch.isValid)
    #expect(patch.routes.count == 48)
    #expect(patch.routes.filter { $0.pedalMode != nil }.count == 28)
    #expect(patch.routes.filter { GamepadFrame.sticks.contains($0.signal) }.count == 16)
}
