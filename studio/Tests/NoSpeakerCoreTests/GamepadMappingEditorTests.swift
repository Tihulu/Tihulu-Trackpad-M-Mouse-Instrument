import Testing
@testable import NoSpeakerCore

@Test func gamepadEditorPreservesOtherSlotAndUnrelatedRoutes() throws {
    let other = SensorMapping(id:"other",source:.gamepad2,signal:.padA,destination:.init(.note,channel:1,number:72))
    let filter = SensorMapping(id:"filter",source:.gamepad1,signal:.padLSX,destination:.init(.controlChange,number:74))
    let old = SensorMapping(id:"old",source:.gamepad1,signal:.padA,destination:.init(.note,number:60))
    let original = InstrumentPatch(routes:[other,filter,old])
    let notes = [60,64,67].map { SensorDestination(.note,number:$0) }
    let edited = try GamepadMappingEditor.replace(in:original,source:.gamepad1,signal:.padA,destinations:notes)
    #expect(edited.routes.contains(other))
    #expect(edited.routes.contains(filter))
    #expect(!edited.routes.contains(old))
    #expect(edited.routes.filter { $0.source == .gamepad1 && $0.signal == .padA }.map(\.destination) == notes)
    let cleared = try GamepadMappingEditor.replace(in:edited,source:.gamepad1,signal:.padA,destinations:[])
    #expect(cleared.routes == [other,filter])
}
@Test func gamepadEditorRejectsInvalidAndReservedDestinations() throws {
    let patch = InstrumentPatch()
    #expect(GamepadMappingEditor.parseNotes("60,64 67") == [60,64,67])
    for invalid in ["", "60,60", "128", "-1", "60.5", "NaN"] {
        #expect(GamepadMappingEditor.parseNotes(invalid) == nil)
    }
    #expect(throws: SensorRouterError.invalidMappings) {
        try GamepadMappingEditor.replace(in:patch,source:.gamepad1,signal:.padLSX,destinations:[.init(.note,number:60)])
    }
    #expect(throws: SensorRouterError.invalidMappings) {
        try GamepadMappingEditor.replace(in:patch,source:.gamepad2,signal:.padA,destinations:[.init(.controlChange,number:101)])
    }
}
@Test func gamepadChordOverlapAndDisconnectKeepOtherControllerSounding() throws {
    let notes = [60,64,67].map { SensorDestination(.note,number:$0) }
    var patch = try GamepadMappingEditor.replace(in:.init(),source:.gamepad1,signal:.padA,destinations:notes)
    patch = try GamepadMappingEditor.replace(in:patch,source:.gamepad2,signal:.padA,destinations:[notes[0]])
    var runtime = PhysicalPatchRuntime()
    try runtime.configure(patch)
    let idle = try #require(GamepadFrame(buttons:Array(repeating:0,count:12),triggers:[0,0],sticks:[0,0,0,0]))
    var buttons = Array(repeating:0.0,count:12); buttons[0] = 1
    let held = try #require(GamepadFrame(buttons:buttons,triggers:[0,0],sticks:[0,0,0,0]))
    _ = runtime.receiveGamepad(source:.gamepad1,frame:idle,now:1)
    _ = runtime.receiveGamepad(source:.gamepad2,frame:idle,now:1)
    var voices = GamepadHapticVoices()
    let on = runtime.receiveGamepad(source:.gamepad1,frame:held,now:1.01)
    #expect(Set(on.map(\.destination)) == Set(notes))
    on.forEach { voices.apply($0) }
    #expect(voices.frame()?.tones.count == 3)
    let shared = runtime.receiveGamepad(source:.gamepad2,frame:held,now:1.02)
    #expect(shared.isEmpty)
    let firstOff = runtime.releaseGamepad(.gamepad1)
    #expect(Set(firstOff.map(\.destination)) == Set(notes.dropFirst()))
    firstOff.forEach { voices.apply($0) }
    #expect(voices.frame()?.tones.count == 1)
    let lastOff = runtime.releaseGamepad(.gamepad2)
    #expect(lastOff == [.init(notes[0],value:0)])
    lastOff.forEach { voices.apply($0) }
    #expect(voices.frame() == nil)
}
@Test func gamepadHapticSustainAndBendRespectChannelAndSafety() throws {
    var voices = GamepadHapticVoices()
    let note = SensorDestination(.note,channel:1,number:60)
    voices.apply(.init(note,value:100))
    let original = try #require(voices.frame())
    voices.apply(.init(.init(.pitchBend,channel:0),value:16383))
    #expect(voices.frame() == original)
    voices.apply(.init(.init(.pitchBend,channel:1),value:16383))
    let bent = try #require(voices.frame())
    #expect(bent.tones[0].frequencyHz > original.tones[0].frequencyHz)
    voices.apply(.init(.init(.sustain,channel:1),value:127))
    voices.apply(.init(note,value:0))
    #expect(voices.frame() != nil)
    voices.apply(.init(.init(.controlChange,channel:1,number:11),value:0))
    #expect(voices.frame() == nil)
    voices.apply(.init(.init(.controlChange,channel:1,number:11),value:127))
    #expect(voices.frame() != nil)
    voices.apply(.init(.init(.sustain,channel:1),value:0))
    #expect(voices.frame() == nil)
    for n in 40..<60 { voices.apply(.init(.init(.note,number:n),value:127)) }
    let limited = try #require(voices.frame())
    #expect(limited.tones.count <= 6)
    #expect(limited.tones.allSatisfy { (98...3951).contains($0.frequencyHz) })
}
