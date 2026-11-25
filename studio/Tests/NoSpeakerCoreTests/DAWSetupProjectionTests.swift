import Testing
@testable import NoSpeakerCore

private func setupPatch() -> InstrumentPatch {
    .init(name:"Two controller setup",routes:[
        .init(id:"note",source:.gamepad1,signal:.padA,destination:.init(.note,channel:0,number:60)),
        .init(id:"pedal",source:.gamepad1,signal:.padRT,destination:.init(.sustain,channel:0)),
        .init(id:"bass",source:.gamepad2,signal:.padA,destination:.init(.note,channel:2,number:40)),
        .init(id:"mod",source:.gamepad2,signal:.padLSX,destination:.init(.controlChange,channel:2,number:1))
    ])
}

@Test func dawSetupDisabledAndInvalidDoNotAdvertisePorts() {
    let patch = setupPatch()
    #expect(patch.isValid)
    let disabled = DAWSetupProjection(patch:patch,sendMIDI:false)
    #expect(disabled.status == .disabled)
    #expect(disabled.port == nil && disabled.channels.isEmpty)
    let empty = DAWSetupProjection(patch:.init(),sendMIDI:true)
    #expect(empty.status == .invalid)
    #expect(empty.port == nil)
    let missingSplit = DAWSetupProjection(patch:patch,sendMIDI:true,splitRequested:true)
    #expect(missingSplit.status == .invalid)
    #expect(missingSplit.channels.isEmpty)
}

@Test func dawSetupProjectsOneBasedChannelsAndRealControlMappings() {
    let setup = DAWSetupProjection(patch:setupPatch(),sendMIDI:true)
    #expect(setup.status == .standard)
    #expect(setup.port == "TIHULU Instrument Builder")
    #expect(setup.channels.map(\.number) == [1,3])
    #expect(setup.channels.first?.notes == ["gamepad1"])
    #expect(setup.channels.first?.controls == ["gamepad1 / padRT: CC 64 (Sustain)"])
    #expect(setup.channels.last?.controls == ["gamepad2 / padLSX: CC 1"])
}

@Test func dawSetupSplitExcludesHapticOnlyChannelsAndRejectsConflict() {
    let patch = setupPatch()
    let selection = GamepadOutputSelection(slot1:.midi,slot2:.haptic)
    let setup = DAWSetupProjection(patch:patch,sendMIDI:false,splitRequested:true,splitSelection:selection)
    #expect(setup.status == .standard)
    #expect(setup.channels.map(\.number) == [1])
    let off = DAWSetupProjection(patch:patch,sendMIDI:true,splitRequested:true,splitSelection:.init(slot1:.haptic,slot2:.haptic))
    #expect(off.status == .disabled && off.port == nil)
    var conflict = patch
    conflict.routes[2].destination.channel = 0
    let blocked = DAWSetupProjection(patch:conflict,sendMIDI:true,splitRequested:true,splitSelection:selection)
    #expect(blocked.status == .invalid && blocked.port == nil)
}

@Test func dawSetupNeverDisplaysLogicalChannelsAsMPEWireChannels() {
    let patch = setupPatch()
    let invalid = DAWSetupProjection(patch:patch,sendMIDI:true,tunedAir:true)
    #expect(invalid.status == .invalid && invalid.port == nil)
    // This flag is supplied only after the host validates the tuned plan.
    // Test the display contract independently of the tuning implementation.
    let tuned = DAWSetupProjection(patch:patch,sendMIDI:true,tunedAir:true,tunedAirValidated:true)
    #expect(tuned.status == .tunedAir)
    #expect(tuned.port == "TIHULU Air Strings MPE")
    #expect(tuned.channels.isEmpty)
}

@Test func dawSetupRenameAndRouteOrderDoNotChangeBuilderPort() {
    let original = setupPatch()
    var changed = original
    changed.name = "Gitar ve Bas"
    changed.routes.reverse()
    let first = DAWSetupProjection(patch:original,sendMIDI:true)
    let second = DAWSetupProjection(patch:changed,sendMIDI:true)
    #expect(first == second)
}
