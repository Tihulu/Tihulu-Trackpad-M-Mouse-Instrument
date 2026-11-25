import Testing
@testable import NoSpeakerCore

@Test func pedalboardPresetPreservesOtherDevicesAndRequiresReplacementConsent() throws {
    let old = SensorMapping(id:"old",source:.gamepad1,signal:.padA,destination:.init(.note,number:60))
    let other = SensorMapping(id:"other",source:.gamepad2,signal:.padA,destination:.init(.note,channel:2,number:67))
    let touch = SensorMapping(id:"touch",source:.trackpad,signal:.contact,destination:.init(.note,channel:1,number:72))
    let base = InstrumentPatch(routes:[old,other,touch])
    #expect(throws:SensorRouterError.invalidMappings) {
        try GamepadPedalboardPreset.install(in:base,source:.gamepad1,channel:3)
    }
    let updated = try GamepadPedalboardPreset.install(in:base,source:.gamepad1,channel:3,replaceExisting:true)
    #expect(updated.routes.contains(other))
    #expect(updated.routes.contains(touch))
    #expect(!updated.routes.contains(old))
    let routes = updated.routes.filter { $0.source == .gamepad1 }
    #expect(routes.count == 10)
    #expect(routes.allSatisfy { $0.destination.channel == 3 })
    #expect(routes.filter { $0.pedalMode == .toggle }.count == 5)
    #expect(routes.filter { $0.pedalMode == .hold }.count == 2)
    #expect(routes.filter { $0.pedalMode == nil }.count == 3)
    #expect(try InstrumentPatch.read(updated.archive()) == updated)
}

@Test func pedalboardPresetRefusesAnalogConflictAndCapacity() throws {
    let analog = SensorMapping(id:"analog",source:.gamepad2,signal:.padLSX,
                              destination:.init(.controlChange,channel:3,number:80))
    let conflicting = InstrumentPatch(routes:[analog])
    #expect(throws:SensorRouterError.invalidMappings) {
        try GamepadPedalboardPreset.install(in:conflicting,source:.gamepad1,channel:3)
    }
    let full = InstrumentPatch(routes:(0..<60).map { i in
        .init(id:"route-\(i)",source:.trackpad,signal:.contact,destination:.init(.note,number:i))
    })
    #expect(full.isValid)
    #expect(throws:SensorRouterError.invalidMappings) {
        try GamepadPedalboardPreset.install(in:full,source:.gamepad1,channel:3)
    }
}

@Test func simulatedPedalLiftPreservesToggleButStopClearsIt() throws {
    let patch = try GamepadPedalboardPreset.install(in:.init(),source:.gamepad1,channel:3)
    var simulation = PatchSimulation()
    try simulation.start(patch,now:1)
    let drive = PatchSimulation.Input(source:.gamepad1,signal:.padA)
    let reverb = PatchSimulation.Input(source:.gamepad1,signal:.padLB)
    let driveTarget = SensorDestination(.controlChange,channel:3,number:80)
    let reverbTarget = SensorDestination(.controlChange,channel:3,number:84)
    let on = simulation.send(drive,value:1,now:1.01)
    #expect(on == [.init(driveTarget,value:127)])
    let lift = simulation.liftGamepadControl(drive,now:1.02)
    #expect(lift.isEmpty)
    let hold = simulation.send(reverb,value:1,now:1.03)
    #expect(hold == [.init(reverbTarget,value:127)])
    let release = simulation.liftGamepadControl(reverb,now:1.04)
    #expect(release == [.init(reverbTarget,value:0)])
    let off = simulation.send(drive,value:1,now:1.05)
    #expect(off == [.init(driveTarget,value:0)])
    _ = simulation.liftGamepadControl(drive,now:1.06)
    _ = simulation.send(drive,value:1,now:1.07)
    let stopped = simulation.stop()
    #expect(stopped == [.init(driveTarget,value:0)])
}

@Test func effectOffDeliveryDebtIsRetriedWithoutResettingOtherChannels() throws {
    let patch = try GamepadPedalboardPreset.install(in:.init(),source:.gamepad1,channel:3)
    var ledger = PatchOutputLedger()
    try ledger.configure(patch)
    let target = SensorDestination(.controlChange,channel:3,number:80)
    let on = ledger.deliver(.init(target,value:127),send:{ _ in true })
    #expect(on)
    let failed = ledger.deliver(.init(target,value:0),send:{ _ in false })
    #expect(!failed)
    #expect(ledger.outstanding == Set([target]))
    var attempted: [SensorCommand] = []
    let first = ledger.releaseAll { command in attempted.append(command); return false }
    #expect(!first)
    #expect(attempted == [.init(target,value:0)])
    let retry = ledger.releaseAll { command in attempted.append(command); return true }
    #expect(retry)
    #expect(attempted == [.init(target,value:0),.init(target,value:0)])
    #expect(ledger.outstanding.isEmpty)
}
