import Foundation
import Testing
@testable import NoSpeakerCore

private func surfaceProfile() -> PerformanceGroupProfile {
    .init(groups:[
        .init(name:"Guitar",patch:.init(routes:[
            .init(id:"note",source:.trackpad,signal:.contact,destination:.init(.note,number:60)),
            .init(id:"bend",source:.trackpad,signal:.x,destination:.init(.pitchBend)),
            .init(id:"mousePedal",source:.magicMouse,signal:.contact,destination:.init(.sustain)),
            .init(id:"padPedal",source:.gamepad1,signal:.padRT,destination:.init(.sustain),pedalMode:.hold)
        ])),
        .init(name:"Bass",patch:.init(routes:[
            .init(id:"bass",source:.gamepad1,signal:.padA,destination:.init(.note,number:48))
        ]))
    ])
}

private func surfaceGamepad(pressed:Bool = false) throws -> GamepadFrame {
    var buttons = Array(repeating:0.0,count:12)
    buttons[0] = pressed ? 1 : 0
    return try #require(GamepadFrame(buttons:buttons,triggers:[0,pressed ? 1 : 0],sticks:[0,0,0,0]))
}

@Test func mixedGroupSurfaceAndGamepadKeepSharedPedalAndOtherInstrument() throws {
    let profile = surfaceProfile()
    let guitar = profile.groups[0].id
    let bass = profile.groups[1].id
    var engine = try PerformanceGroupGamepadSession(profile:profile,allowSurfaces:true)
    let touch = try engine.bind(.trackpad,now:0)
    let mouse = try engine.bind(.magicMouse,now:0)
    let pad = try engine.bind(.gamepad1,now:0)
    var events: [PerformanceGroupCommand] = []
    let sink: (PerformanceGroupCommand) -> Bool = { events.append($0); return true }
    _ = engine.receiveSurface(.trackpad,token:touch,x:nil,y:nil,size:nil,hostTime:0,now:0,send:sink)
    _ = engine.receiveSurface(.magicMouse,token:mouse,x:nil,y:nil,size:nil,hostTime:0,now:0,send:sink)
    _ = engine.receive(.gamepad1,token:pad,frame:try surfaceGamepad(),now:0,send:sink)
    _ = engine.receiveSurface(.trackpad,token:touch,x:0.8,y:0.5,size:0.6,hostTime:0.01,now:0.01,send:sink)
    #expect(events.map { $0.command.destination.kind } == [.pitchBend,.note])
    _ = engine.receiveSurface(.magicMouse,token:mouse,x:0.5,y:0.5,size:0.5,hostTime:0.02,now:0.02,send:sink)
    _ = engine.receive(.gamepad1,token:pad,frame:try surfaceGamepad(pressed:true),now:0.03,send:sink)
    #expect(events.filter { $0.command.destination.kind == .sustain }.count == 1)
    #expect(events.contains { $0.groupID == bass && $0.command.value == 100 })
    events.removeAll()
    _ = engine.receiveSurface(.magicMouse,token:mouse,x:nil,y:nil,size:nil,hostTime:0.04,now:0.04,send:sink)
    #expect(events.isEmpty)
    _ = engine.receiveSurface(.trackpad,token:touch,x:nil,y:nil,size:nil,hostTime:0.05,now:0.05,send:sink)
    #expect(events.count == 2 && events.allSatisfy { $0.groupID == guitar })
    #expect(!events.contains { $0.command.destination.kind == .sustain })
    events.removeAll()
    _ = engine.receive(.gamepad1,token:pad,frame:try surfaceGamepad(),now:0.06,send:sink)
    #expect(events.contains(.init(groupID:guitar,command:.init(.init(.sustain),value:0))))
    #expect(events.contains(.init(groupID:bass,command:.init(.init(.note,number:48),value:0))))
}

@Test func mixedGroupSurfaceRequiresNeutralAndRejectsInvalidOrStaleSamples() throws {
    var engine = try PerformanceGroupGamepadSession(profile:surfaceProfile(),allowSurfaces:true)
    let id = try engine.bind(.trackpad,now:1)
    var events: [PerformanceGroupCommand] = []
    let sink: (PerformanceGroupCommand) -> Bool = { events.append($0); return true }
    let held = engine.receiveSurface(.trackpad,token:id,x:0.5,y:0.5,size:0.5,hostTime:1,now:1,send:sink)
    #expect(held.status == .waitingForNeutral && events.isEmpty)
    let invalid = engine.receiveSurface(.trackpad,token:id,x:nil,y:nil,size:0.5,hostTime:1.01,now:1.01,send:sink)
    #expect(invalid.status == .lost)
    let old = engine.receiveSurface(.trackpad,token:id,x:nil,y:nil,size:nil,hostTime:1,now:1.02,send:sink)
    #expect(old.status == .lost)
    let blocked = engine.receiveSurface(.trackpad,token:id,x:0.5,y:0.5,size:0.5,hostTime:1.03,now:1.03,send:sink)
    #expect(blocked.status == .waitingForNeutral && events.isEmpty)
    _ = engine.receiveSurface(.trackpad,token:id,x:nil,y:nil,size:nil,hostTime:1.04,now:1.04,send:sink)
    _ = engine.receiveSurface(.trackpad,token:id,x:0.5,y:0.5,size:0.5,hostTime:1.05,now:1.3,send:sink)
    #expect(events.contains { $0.command.destination.kind == .note && $0.command.value > 0 })
    events.removeAll()
    _ = engine.expire(now:1.41,send:sink)
    #expect(events.contains { $0.command.destination.kind == .note && $0.command.value == 0 })
    events.removeAll()
    let stale = engine.receiveSurface(.trackpad,token:id,x:nil,y:nil,size:nil,hostTime:1.06,now:1.42,send:sink)
    #expect(stale.status == .lost)
    let next = engine.receiveSurface(.trackpad,token:id,x:0.5,y:0.5,size:0.5,hostTime:1.43,now:1.43,send:sink)
    #expect(next.status == .waitingForNeutral && events.isEmpty)
}

@Test func mixedGroupSameFramePedalBeforeNoteAndNoForeignDeviceFrame() throws {
    let group = PerformanceInstrumentGroup(name:"Both",patch:.init(routes:[
        .init(id:"note",source:.trackpad,signal:.contact,destination:.init(.note,number:60)),
        .init(id:"pedal",source:.trackpad,signal:.contact,destination:.init(.sustain))
    ]))
    var engine = try PerformanceGroupGamepadSession(profile:.init(groups:[group]),allowSurfaces:true)
    let id = try engine.bind(.trackpad,now:0)
    var output: [PerformanceGroupCommand] = []
    let sink: (PerformanceGroupCommand) -> Bool = { output.append($0); return true }
    let wrong = engine.receive(.trackpad,token:id,frame:try surfaceGamepad(),now:0,send:sink)
    #expect(wrong.status == .ignored)
    _ = engine.receiveSurface(.trackpad,token:id,x:nil,y:nil,size:nil,hostTime:0,now:0,send:sink)
    _ = engine.receiveSurface(.trackpad,token:id,x:0.5,y:0.5,size:0.5,hostTime:0.01,now:0.01,send:sink)
    #expect(output.map { $0.command.destination.kind } == [.sustain,.note])
}

@Test func mixedGroupRejectsUnsupportedPhoneAndPressureRoutes() throws {
    for (source,signal) in [(SensorSource.phone,SensorSignal.contact),(.trackpad,.pressure)] {
        let profile = PerformanceGroupProfile(groups:[.init(name:"Unsupported",patch:.init(routes:[
            .init(id:"unsupported",source:source,signal:signal,destination:.init(.note,number:60))
        ]))])
        #expect(!PerformanceGroupGamepadSession.supports(profile,allowSurfaces:true))
        #expect(throws: PerformanceGroupGamepadSession.AdmissionError.unsupportedProfile) {
            try PerformanceGroupGamepadSession(profile:profile,allowSurfaces:true)
        }
    }
}


@Test func groupSurfaceCannotArmFromBeforeItsBindingEpoch() throws {
    let group = PerformanceInstrumentGroup(name:"Touch",patch:.init(routes:[
        .init(id:"note",source:.trackpad,signal:.contact,destination:.init(.note,number:60))
    ]))
    var session = try PerformanceGroupGamepadSession(profile:.init(groups:[group]),allowSurfaces:true)
    let token = try session.bind(.trackpad,now:1)
    var sent:[PerformanceGroupCommand] = []
    let sink:(PerformanceGroupCommand)->Bool = { sent.append($0); return true }
    let before = session.receiveSurface(.trackpad,token:token,x:nil,y:nil,size:nil,hostTime:0.99,now:1.01,send:sink)
    #expect(before.status == .lost)
    let held = session.receiveSurface(.trackpad,token:token,x:0.5,y:0.5,size:0.5,hostTime:1.02,now:1.02,send:sink)
    #expect(held.status == .waitingForNeutral && sent.isEmpty)
    _ = session.receiveSurface(.trackpad,token:token,x:nil,y:nil,size:nil,hostTime:1.03,now:1.03,send:sink)
    _ = session.receiveSurface(.trackpad,token:token,x:0.5,y:0.5,size:0.5,hostTime:1.04,now:1.04,send:sink)
    #expect(sent.count == 1 && sent.first?.command.value == 100)
}
