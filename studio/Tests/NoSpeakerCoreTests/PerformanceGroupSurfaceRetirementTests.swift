import Foundation
import Testing
@testable import NoSpeakerCore

@Test func groupSurfaceBatchLossDoesNotRestoreDepartingCCOrStopXbox() throws {
    let target = SensorDestination(.controlChange,number:74)
    let surface = PerformanceInstrumentGroup(name:"Surface",patch:.init(routes:[
        .init(id:"track",source:.trackpad,signal:.x,destination:target,priority:10),
        .init(id:"mouse",source:.magicMouse,signal:.x,destination:target)
    ]))
    let local = PerformanceInstrumentGroup(name:"Xbox",patch:.init(routes:[
        .init(id:"note",source:.gamepad1,signal:.padA,destination:.init(.note,number:60))
    ]))
    var session = try PerformanceGroupGamepadSession(profile:.init(groups:[surface,local]),allowSurfaces:true)
    let a = try session.bind(.trackpad,now:1)
    let b = try session.bind(.magicMouse,now:1)
    let c = try session.bind(.gamepad1,now:1)
    var sent:[PerformanceGroupCommand] = []
    let sink:(PerformanceGroupCommand)->Bool = { sent.append($0);return true }
    for (source,token) in [(SensorSource.trackpad,a),(.magicMouse,b)] {
        _ = session.receiveSurface(source,token:token,x:nil,y:nil,size:nil,hostTime:1.01,now:1.01,send:sink)
    }
    let neutral = try #require(GamepadFrame(buttons:Array(repeating:0.0,count:12),triggers:[0,0],sticks:[0,0,0,0]))
    var buttons = Array(repeating:0.0,count:12);buttons[0] = 1
    let down = try #require(GamepadFrame(buttons:buttons,triggers:[0,0],sticks:[0,0,0,0]))
    _ = session.receive(.gamepad1,token:c,frame:neutral,now:1.02,send:sink)
    _ = session.receiveSurface(.trackpad,token:a,x:1,y:0.5,size:0.5,hostTime:1.03,now:1.03,send:sink)
    _ = session.receiveSurface(.magicMouse,token:b,x:0.5,y:0.5,size:0.5,hostTime:1.04,now:1.04,send:sink)
    _ = session.receive(.gamepad1,token:c,frame:down,now:1.05,send:sink)
    #expect(sent.count == 2)
    sent.removeAll()
    let result = session.unbindBatch([.trackpad:a,.magicMouse:b,.gamepad1:UUID()],send:sink)
    #expect(result.count == 1)
    #expect(sent == [.init(groupID:surface.id,command:.init(target,value:0))])
    #expect(session.boundSources == [.gamepad1] && session.activeSessions == 1)
    sent.removeAll()
    let old = session.receiveSurface(.trackpad,token:a,x:1,y:0.5,size:0.5,hostTime:1.06,now:1.06,send:sink)
    #expect(old.status == .ignored && sent.isEmpty)
    let replacement = try session.bind(.trackpad,now:1.07)
    _ = session.unbindBatch([.trackpad:a],send:sink)
    #expect(session.boundSources == [.trackpad,.gamepad1])
    let held = session.receiveSurface(.trackpad,token:replacement,x:1,y:0.5,size:0.5,hostTime:1.08,now:1.08,send:sink)
    #expect(held.status == .waitingForNeutral && sent.isEmpty)
    _ = session.receive(.gamepad1,token:c,frame:neutral,now:1.09,send:sink)
    #expect(sent.count == 1 && sent.first?.groupID == local.id && sent.first?.command.value == 0)
}
