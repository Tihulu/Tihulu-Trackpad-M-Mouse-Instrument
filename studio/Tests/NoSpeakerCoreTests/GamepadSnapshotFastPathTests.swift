import Testing
@testable import NoSpeakerCore

private func snapshot(a:Bool = false,b:Bool = false,stick:Double = 0) throws -> GamepadFrame {
    var buttons = Array(repeating:0.0,count:12)
    buttons[0] = a ? 1 : 0
    buttons[1] = b ? 1 : 0
    return try #require(GamepadFrame(buttons:buttons,triggers:[0,0],sticks:[stick,0,0,0]))
}

@Test func duplicateNativeGamepadSnapshotsRenewLeaseWithoutReplayingEffects() throws {
    let target = SensorDestination(.controlChange,channel:3,number:80)
    let route = SensorMapping(id:"switch",source:.gamepad1,signal:.padA,destination:target,pedalMode:.toggle)
    var runtime = PhysicalPatchRuntime()
    try runtime.configure(.init(routes:[route]))
    let idle = try snapshot(), down = try snapshot(a:true)
    _ = runtime.receiveGamepad(source:.gamepad1,frame:idle,now:1)
    let on = runtime.receiveGamepad(source:.gamepad1,frame:down,now:1.01)
    #expect(on == [.init(target,value:127)])
    for i in 1...1000 {
        let now = 1.01+Double(i)*0.01
        let repeatFrame = runtime.receiveGamepad(source:.gamepad1,frame:down,now:now)
        #expect(repeatFrame.isEmpty)
        let expired = runtime.expire(now:now)
        #expect(expired.isEmpty)
    }
    #expect(runtime.gamepadSnapshotMetrics.accepted == 1001)
    #expect(runtime.gamepadSnapshotMetrics.skippedDuplicates == 1000)
    #expect(runtime.gamepadSnapshotMetrics.mappedEvents == 1)
    let lift = runtime.receiveGamepad(source:.gamepad1,frame:idle,now:11.02)
    #expect(lift.isEmpty)
    let off = runtime.receiveGamepad(source:.gamepad1,frame:down,now:11.03)
    #expect(off == [.init(target,value:0)])
    let stopped = runtime.stop()
    #expect(stopped.isEmpty)
}

@Test func gamepadFastPathDoesNotSkipSmoothingOrSendUnmappedControls() throws {
    let target = SensorDestination(.controlChange,number:74)
    let response = ContinuousResponse(smoothingMS:100)
    let route = SensorMapping(id:"filter",source:.gamepad1,signal:.padLSX,destination:target,response:response)
    var runtime = PhysicalPatchRuntime()
    try runtime.configure(.init(routes:[route]))
    _ = runtime.receiveGamepad(source:.gamepad1,frame:try snapshot(),now:1)
    let low = try snapshot(a:true,stick:-1)
    let high = try snapshot(a:true,b:true,stick:1)
    let first = runtime.receiveGamepad(source:.gamepad1,frame:low,now:1.01)
    #expect(first == [.init(target,value:0)])
    var value = 0.0
    var wire = 0
    var previousTime = 1.01
    for i in 1...100 {
        let now = 1.01+Double(i)*0.01
        value = response.smooth(1,previous:value,elapsed:now-previousTime)
        let next = response.output(value,target:target)
        let actual = runtime.receiveGamepad(source:.gamepad1,frame:high,now:now)
        #expect(actual == (next == wire ? [] : [.init(target,value:next)]))
        wire = next
        previousTime = now
    }
    #expect(wire == 127)
    #expect(runtime.gamepadSnapshotMetrics.skippedDuplicates == 0)
    #expect(runtime.gamepadSnapshotMetrics.mappedEvents == 101)
    let released = runtime.releaseGamepad(.gamepad1)
    #expect(released == [.init(target,value:0)])
}

@Test func gamepadDuplicateCacheIsScopedAndClearedAfterWatchdogRetirement() throws {
    let a = SensorDestination(.note,channel:1,number:60)
    let b = SensorDestination(.note,channel:2,number:67)
    var runtime = PhysicalPatchRuntime()
    try runtime.configure(.init(routes:[
        .init(id:"one",source:.gamepad1,signal:.padA,destination:a),
        .init(id:"two",source:.gamepad2,signal:.padA,destination:b)
    ]))
    let idle = try snapshot(), pressed = try snapshot(a:true)
    _ = runtime.receiveGamepad(source:.gamepad1,frame:idle,now:1)
    _ = runtime.receiveGamepad(source:.gamepad2,frame:idle,now:1)
    let first = runtime.receiveGamepad(source:.gamepad1,frame:pressed,now:1.01)
    let second = runtime.receiveGamepad(source:.gamepad2,frame:pressed,now:1.01)
    #expect(first == [.init(a,value:100)])
    #expect(second == [.init(b,value:100)])
    _ = runtime.receiveGamepad(source:.gamepad2,frame:pressed,now:1.30)
    let expired = runtime.expire(now:1.37)
    #expect(expired == [.init(a,value:0)])
    let blocked = runtime.receiveGamepad(source:.gamepad1,frame:pressed,now:1.38)
    #expect(blocked.isEmpty)
    _ = runtime.receiveGamepad(source:.gamepad1,frame:idle,now:1.39)
    let rearmed = runtime.receiveGamepad(source:.gamepad1,frame:pressed,now:1.40)
    #expect(rearmed == [.init(a,value:100)])
    let stopped = runtime.stop()
    #expect(stopped == [.init(a,value:0),.init(b,value:0)])
}

@Test func gamepadSnapshotMetricsSaturateAndRejectInvalidCounts() {
    var metrics = GamepadSnapshotMetrics()
    metrics.record(skipped:true,events:1)
    metrics.record(skipped:false,events:-1)
    #expect(metrics.accepted == 0)
    metrics.record(skipped:false,events:Int.max)
    metrics.record(skipped:false,events:1)
    metrics.record(skipped:true,events:0)
    #expect(metrics.accepted == 3)
    #expect(metrics.skippedDuplicates == 1)
    #expect(metrics.mappedEvents == Int.max)
}
