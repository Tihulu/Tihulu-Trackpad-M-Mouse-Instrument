import Testing
@testable import NoSpeakerCore

private func mappedControllers(_ secondChannel:Int) -> InstrumentPatch {
    .init(routes:[
        .init(id:"firstNote",source:.gamepad1,signal:.padA,destination:.init(.note,channel:0,number:60)),
        .init(id:"firstPedal",source:.gamepad1,signal:.padRT,destination:.init(.sustain,channel:0)),
        .init(id:"secondNote",source:.gamepad2,signal:.padA,destination:.init(.note,channel:secondChannel,number:60)),
        .init(id:"secondPedal",source:.gamepad2,signal:.padRT,destination:.init(.sustain,channel:secondChannel))
    ])
}

@Test func gamepadOutputPlanSeparatesNotesAndPedals() throws {
    let patch = mappedControllers(1)
    let plan = try #require(GamepadOutputPlan(patch:patch,selection:.init(slot1:.midi,slot2:.haptic)))
    #expect(plan.hasMIDI && plan.hasHaptics)
    for route in patch.routes {
        #expect(plan.sendsMIDI(route.destination) == (route.source == .gamepad1))
        #expect(plan.sendsHaptics(route.destination) == (route.source == .gamepad2))
    }
    #expect(!plan.sendsMIDI(.init(.note,channel:2,number:60)))
    #expect(!plan.sendsHaptics(.init(.note,channel:1,number:128)))
}

@Test func gamepadOutputPlanRejectsConflictingSharedChannelAndMixedDevices() throws {
    let shared = mappedControllers(0)
    #expect(GamepadOutputPlan(patch:shared,selection:.init(slot1:.midi,slot2:.haptic)) == nil)
    let both = try #require(GamepadOutputPlan(patch:shared,selection:.init(slot1:.both,slot2:.both)))
    #expect(both.sendsMIDI(.init(.note,number:60)))
    #expect(both.sendsHaptics(.init(.note,number:60)))
    var mixed = mappedControllers(1)
    mixed.routes.append(.init(id:"other",source:.trackpad,signal:.contact,destination:.init(.note,number:48)))
    #expect(GamepadOutputPlan(patch:mixed,selection:.init()) == nil)
    mixed.routes.removeAll { $0.source != .gamepad1 }
    #expect(GamepadOutputPlan(patch:mixed,selection:.init()) == nil)
}

@Test func gamepadSplitOutputFiltersDisconnectAndPreservesOtherSlot() throws {
    let patch = mappedControllers(1)
    let plan = try #require(GamepadOutputPlan(patch:patch,selection:.init(slot1:.midi,slot2:.haptic)))
    var runtime = PhysicalPatchRuntime()
    try runtime.configure(patch)
    let idle = try #require(GamepadFrame(buttons:Array(repeating:0,count:12),triggers:[0,0],sticks:[0,0,0,0]))
    var buttons = Array(repeating:0.0,count:12); buttons[0] = 1
    let held = try #require(GamepadFrame(buttons:buttons,triggers:[0,0],sticks:[0,0,0,0]))
    _ = runtime.receiveGamepad(source:.gamepad1,frame:idle,now:1)
    _ = runtime.receiveGamepad(source:.gamepad2,frame:idle,now:1)
    let first = runtime.receiveGamepad(source:.gamepad1,frame:held,now:1.01)
    let second = runtime.receiveGamepad(source:.gamepad2,frame:held,now:1.02)
    #expect(first.count == 1 && first.allSatisfy { plan.sendsMIDI($0.destination) && !plan.sendsHaptics($0.destination) })
    #expect(second.count == 1 && second.allSatisfy { plan.sendsHaptics($0.destination) && !plan.sendsMIDI($0.destination) })
    var haptics = GamepadHapticVoices()
    (first+second).filter { plan.sendsHaptics($0.destination) }.forEach { haptics.apply($0) }
    #expect(haptics.frame() != nil)
    let off1 = runtime.releaseGamepad(.gamepad1)
    #expect(off1.count == 1 && off1.allSatisfy { $0.value == 0 && plan.sendsMIDI($0.destination) && !plan.sendsHaptics($0.destination) })
    off1.filter { plan.sendsHaptics($0.destination) }.forEach { haptics.apply($0) }
    #expect(haptics.frame() != nil)
    let off2 = runtime.releaseGamepad(.gamepad2)
    #expect(off2.count == 1 && off2.allSatisfy { $0.value == 0 && plan.sendsHaptics($0.destination) && !plan.sendsMIDI($0.destination) })
    off2.filter { plan.sendsHaptics($0.destination) }.forEach { haptics.apply($0) }
    #expect(haptics.frame() == nil)
}
