import Foundation
import Testing
@testable import NoSpeakerCore

private func durationFrame(button:Bool = false,trigger:Double = 0,stick:Double = 0) throws -> GamepadFrame {
    var buttons = Array(repeating:0.0,count:12)
    buttons[0] = button ? 1 : 0
    return try #require(GamepadFrame(buttons:buttons,triggers:[0,trigger],sticks:[stick,0,0,0]))
}

@Test func groupLongNoteAndIndependentSustainDoNotRetriggerOrReleasePrematurely() throws {
    let note = SensorDestination(.note,number:60)
    let sustain = SensorDestination(.sustain)
    let group = PerformanceInstrumentGroup(name:"Held note",patch:.init(routes:[
        .init(id:"note",source:.gamepad1,signal:.padA,destination:note),
        .init(id:"sustain",source:.gamepad2,signal:.padRT,destination:sustain)
    ]))
    let sibling = PerformanceInstrumentGroup(name:"Independent note",patch:.init(routes:[
        .init(id:"other",source:.gamepad3,signal:.padA,destination:note)
    ]))
    var session = try PerformanceGroupGamepadSession(profile:.init(groups:[group,sibling]))
    let a = try session.bind(.gamepad1,now:1)
    let b = try session.bind(.gamepad2,now:1)
    let c = try session.bind(.gamepad3,now:1)
    let neutral = try durationFrame()
    let held = try durationFrame(button:true)
    let pedal = try durationFrame(trigger:1)
    var sent:[PerformanceGroupCommand] = []
    let sink:(PerformanceGroupCommand)->Bool = { sent.append($0);return true }
    for (source,token) in [(SensorSource.gamepad1,a),(.gamepad2,b),(.gamepad3,c)] {
        _ = session.receive(source,token:token,frame:neutral,now:1,send:sink)
    }
    for tick in 1...500 {
        let now = 1+Double(tick)*0.02
        _ = session.expire(now:now,send:sink)
        _ = session.receive(.gamepad1,token:a,frame:held,now:now,send:sink)
        _ = session.receive(.gamepad2,token:b,frame:pedal,now:now,send:sink)
        _ = session.receive(.gamepad3,token:c,frame:held,now:now,send:sink)
    }
    #expect(sent == [
        .init(groupID:group.id,command:.init(note,value:100)),
        .init(groupID:group.id,command:.init(sustain,value:127)),
        .init(groupID:sibling.id,command:.init(note,value:100))
    ])
    sent.removeAll()
    _ = session.receive(.gamepad1,token:a,frame:neutral,now:11.02,send:sink)
    #expect(sent == [.init(groupID:group.id,command:.init(note,value:0))])
    sent.removeAll()
    _ = session.unbind(.gamepad2,token:b,send:sink)
    #expect(sent == [.init(groupID:group.id,command:.init(sustain,value:0))])
    sent.removeAll()
    _ = session.receive(.gamepad3,token:c,frame:neutral,now:11.04,send:sink)
    #expect(sent == [.init(groupID:sibling.id,command:.init(note,value:0))])
}

@Test func groupSimultaneousXboxLossDoesNotRestoreDepartingEffect() throws {
    let target = SensorDestination(.controlChange,number:74)
    let group = PerformanceInstrumentGroup(name:"Shared filter",patch:.init(routes:[
        .init(id:"high",source:.gamepad1,signal:.padLSX,destination:target,priority:10),
        .init(id:"low",source:.gamepad2,signal:.padLSX,destination:target)
    ]))
    var session = try PerformanceGroupGamepadSession(profile:.init(groups:[group]))
    let a = try session.bind(.gamepad1,now:1), b = try session.bind(.gamepad2,now:1)
    let neutral = try durationFrame(), high = try durationFrame(stick:1), low = try durationFrame(stick:0.5)
    var sent:[PerformanceGroupCommand] = []
    let sink:(PerformanceGroupCommand)->Bool = { sent.append($0);return true }
    _ = session.receive(.gamepad1,token:a,frame:neutral,now:1,send:sink)
    _ = session.receive(.gamepad2,token:b,frame:neutral,now:1,send:sink)
    _ = session.receive(.gamepad1,token:a,frame:high,now:1.01,send:sink)
    _ = session.receive(.gamepad2,token:b,frame:low,now:1.02,send:sink)
    #expect(sent.map(\.command.value) == [127])
    sent.removeAll()
    _ = session.unbindBatch([.gamepad1:a,.gamepad2:b],send:sink)
    #expect(sent.map(\.command.value) == [0])
    #expect(session.boundSources.isEmpty && session.activeSessions == 0)
}
