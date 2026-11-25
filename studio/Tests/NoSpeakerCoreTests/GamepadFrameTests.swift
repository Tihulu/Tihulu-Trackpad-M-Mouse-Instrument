import Testing
@testable import NoSpeakerCore

private func frame(a:Bool = false,rt:Double = 0) throws -> GamepadFrame {
    var buttons = Array(repeating:0.0,count:12); buttons[0] = a ? 1 : 0
    return try #require(GamepadFrame(buttons:buttons,triggers:[0,rt],sticks:[0,0,0,0]))
}
@Test func gamepadsHaveIndependentOwnershipAndRequireNeutralAfterLoss() throws {
    let note = SensorDestination(.note,number:60)
    let routes = [SensorSource.gamepad1,.gamepad2].map {
        SensorMapping(id:$0.rawValue,source:$0,signal:.padA,destination:note)
    }
    var runtime = PhysicalPatchRuntime()
    try runtime.configure(.init(routes:routes))
    let idle = try frame(), held = try frame(a:true)
    let initial = runtime.receiveGamepad(source:.gamepad1,frame:held,now:1)
    #expect(initial.isEmpty)
    _ = runtime.receiveGamepad(source:.gamepad1,frame:idle,now:1.01)
    _ = runtime.receiveGamepad(source:.gamepad2,frame:idle,now:1.01)
    let on = runtime.receiveGamepad(source:.gamepad1,frame:held,now:1.02)
    #expect(on == [.init(note,value:100)])
    let shared = runtime.receiveGamepad(source:.gamepad2,frame:held,now:1.03)
    #expect(shared.isEmpty)
    let first = runtime.releaseGamepad(.gamepad1)
    #expect(first.isEmpty)
    let stale = runtime.receiveGamepad(source:.gamepad1,frame:held,now:1.04)
    #expect(stale.isEmpty)
    let second = runtime.releaseGamepad(.gamepad2)
    #expect(second == [.init(note,value:0)])
    _ = runtime.receiveGamepad(source:.gamepad1,frame:idle,now:1.05)
    let rearmed = runtime.receiveGamepad(source:.gamepad1,frame:held,now:1.06)
    #expect(rearmed == [.init(note,value:100)])
    let expired = runtime.receiveGamepad(source:.gamepad1,frame:held,now:1.5)
    #expect(expired == [.init(note,value:0)])
}
@Test func gamepadFramesRejectInvalidAndUnmappedSources() {
    #expect(GamepadFrame(buttons:Array(repeating:0,count:12),triggers:[0,.nan],sticks:[0,0,0,0]) == nil)
    #expect(!GamepadFrame.permits(.init(id:"bad",source:.phone,signal:.padA,destination:.init(.note,number:60))))
    #expect(!GamepadFrame.permits(.init(id:"bad",source:.gamepad1,signal:.padLSX,destination:.init(.note,number:60))))
}
