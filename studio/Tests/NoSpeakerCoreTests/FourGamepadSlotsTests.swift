import Testing
@testable import NoSpeakerCore

private func fourSlotPatch() -> InstrumentPatch {
    .init(routes:GamepadFrame.orderedSources.enumerated().map { i,source in
        .init(id:"slot-\(i)",source:source,signal:.padA,
              destination:.init(.note,channel:i,number:60+i))
    })
}

@Test func fourGamepadsReserveExistingSessionBudgetAndReleaseIndependently() throws {
    let patch = fourSlotPatch()
    #expect(GamepadFrame.orderedSources.count == 4)
    #expect(patch.isValid)
    var runtime = PhysicalPatchRuntime()
    try runtime.configure(patch)
    #expect(runtime.reservedGamepadSessions == 4)
    #expect(runtime.remoteSessionLimit == 7)
    let idle = try #require(GamepadFrame(buttons:Array(repeating:0,count:12),triggers:[0,0],sticks:[0,0,0,0]))
    var buttons = Array(repeating:0.0,count:12)
    buttons[0] = 1
    let down = try #require(GamepadFrame(buttons:buttons,triggers:[0,0],sticks:[0,0,0,0]))
    for (i,source) in GamepadFrame.orderedSources.enumerated() {
        #expect(runtime.receiveGamepad(source:source,frame:down,now:1).isEmpty)
        _ = runtime.receiveGamepad(source:source,frame:idle,now:1.01)
        let commands = runtime.receiveGamepad(source:source,frame:down,now:1.02)
        #expect(commands == [.init(.init(.note,channel:i,number:60+i),value:100)])
    }
    #expect(runtime.activeRouterSessionCount == 4)
    let thirdOff = runtime.releaseGamepad(.gamepad3)
    #expect(thirdOff == [.init(.init(.note,channel:2,number:62),value:0)])
    #expect(runtime.activeSources == Set([.gamepad1,.gamepad2,.gamepad4]))
    let stopped = runtime.stop()
    #expect(Set(stopped.map(\.destination.channel)) == Set([0,1,3]))
    #expect(stopped.allSatisfy { $0.value == 0 })
    #expect(runtime.activeRouterSessionCount == 0)
}

@Test func fourGamepadsCanChooseDistinctOutputsWithoutCrossChannelLeakage() throws {
    let patch = fourSlotPatch()
    let selection = GamepadOutputSelection(slot1:.midi,slot2:.haptic,slot3:.both,slot4:.midi)
    let plan = try #require(GamepadOutputPlan(patch:patch,selection:selection))
    for route in patch.routes {
        let output = try #require(selection.output(for:route.source))
        #expect(plan.sendsMIDI(route.destination) == output.sendsMIDI)
        #expect(plan.sendsHaptics(route.destination) == output.sendsHaptics)
    }
    var conflict = patch
    conflict.routes[3].destination.channel = 1
    #expect(GamepadOutputPlan(patch:conflict,selection:selection) == nil)
    var nonConsecutive = patch
    nonConsecutive.routes.removeAll { $0.source == .gamepad1 || $0.source == .gamepad3 }
    #expect(GamepadOutputPlan(patch:nonConsecutive,selection:selection) != nil)
}

@Test func fourGamepadArchiveCopyAndPedalboardRemainScoped() throws {
    let base = try GamepadPedalboardPreset.install(in:.init(),source:.gamepad3,channel:2)
    let copied = try GamepadMappingEditor.copy(in:base,from:.gamepad3,to:.gamepad4,channel:3)
    #expect(copied.routes.count == 20)
    #expect(copied.routes.filter { $0.source == .gamepad3 } == base.routes)
    #expect(copied.routes.filter { $0.source == .gamepad4 && $0.pedalMode == .toggle }.count == 5)
    let archive = try copied.archive()
    #expect(try InstrumentPatch.read(archive) == copied)
    #expect(throws:SensorRouterError.invalidMappings) {
        try GamepadMappingEditor.copy(in:copied,from:.gamepad3,to:.gamepad4)
    }
}

@Test func twoSlotDefaultsAndReservationRemainCompatible() throws {
    let selection = GamepadOutputSelection()
    #expect(selection.output(for:.gamepad1) == .midi)
    #expect(selection.output(for:.gamepad2) == .haptic)
    #expect(selection.output(for:.trackpad) == nil)
    var runtime = PhysicalPatchRuntime()
    var patch = fourSlotPatch()
    patch.routes.removeAll { $0.source == .gamepad3 || $0.source == .gamepad4 }
    try runtime.configure(patch)
    #expect(runtime.reservedGamepadSessions == 2)
    #expect(runtime.remoteSessionLimit == 9)
    #expect(GamepadOutputPlan(patch:patch,selection:selection) != nil)
}
