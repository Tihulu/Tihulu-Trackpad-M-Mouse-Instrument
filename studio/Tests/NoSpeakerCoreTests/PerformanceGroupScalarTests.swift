import Foundation
import Testing
@testable import NoSpeakerCore

private func scalarGroupProfile() -> PerformanceGroupProfile {
    .init(groups:[
        .init(name:"Effects",patch:.init(routes:[
            .init(id:"lid",source:.lid,signal:.angle,destination:.init(.controlChange,number:74),priority:0),
            .init(id:"bar",source:.touchBar,signal:.x,destination:.init(.controlChange,number:74),priority:10)
        ])),
        .init(name:"Notes",patch:.init(routes:[
            .init(id:"note",source:.trackpad,signal:.contact,destination:.init(.note,number:60))
        ]))
    ])
}

@Test func groupScalarSharedEffectRestoresOnlyLiveOwnerAndPreservesNotes() throws {
    let profile = scalarGroupProfile()
    var state = try PerformanceGroupGamepadSession(profile:profile,allowSurfaces:true,allowScalars:true)
    let lid = try state.bind(.lid,now:0)
    let bar = try state.bind(.touchBar,now:0)
    let touch = try state.bind(.trackpad,now:0)
    var output: [PerformanceGroupCommand] = []
    let sink: (PerformanceGroupCommand) -> Bool = { output.append($0); return true }
    _ = state.receiveSurface(.trackpad,token:touch,x:nil,y:nil,size:nil,hostTime:0,now:0,send:sink)
    _ = state.receiveSurface(.trackpad,token:touch,x:0.5,y:0.5,size:0.5,hostTime:0.01,now:0.01,send:sink)
    _ = state.receiveScalar(.lid,token:lid,value:0.2,hostTime:0.02,now:0.02,send:sink)
    _ = state.receiveScalar(.touchBar,token:bar,value:0.8,hostTime:0.03,now:0.03,send:sink)
    _ = state.receiveScalar(.touchBar,token:bar,value:nil,hostTime:0.04,now:0.04,send:sink)
    #expect(output.filter { $0.groupID == profile.groups[0].id }.map { $0.command.value } == [25,102,25])
    #expect(output.filter { $0.groupID == profile.groups[1].id }.map { $0.command.value } == [100])
    _ = state.receiveSurface(.trackpad,token:touch,x:0.5,y:0.5,size:0.5,hostTime:0.3,now:0.3,send:sink)
    _ = state.expire(now:0.38,send:sink)
    #expect(output.last == .init(groupID:profile.groups[0].id,command:.init(.init(.controlChange,number:74),value:0)))
    #expect(state.activeSessions == 1)
    let blocked = state.receiveScalar(.lid,token:lid,value:0.9,hostTime:0.39,now:0.39,send:sink)
    #expect(blocked.status == .waitingForNeutral)
    #expect(state.activeSessions == 1)
}

@Test func groupScalarTouchBarRequiresReleaseAfterTimeoutAndFencesOldToken() throws {
    let profile = scalarGroupProfile()
    var state = try PerformanceGroupGamepadSession(profile:profile,allowSurfaces:true,allowScalars:true)
    let id = try state.bind(.touchBar,now:0)
    #expect(state.sourceStates[.touchBar] == .armed)
    var output: [PerformanceGroupCommand] = []
    let sink: (PerformanceGroupCommand) -> Bool = { output.append($0); return true }
    _ = state.receiveScalar(.touchBar,token:id,value:0.8,hostTime:0.01,now:0.01,send:sink)
    #expect(state.sourceStates[.touchBar] == .leased)
    _ = state.expire(now:0.37,send:sink)
    #expect(state.sourceStates[.touchBar] == .waitingForNeutral)
    let held = state.receiveScalar(.touchBar,token:id,value:0.9,hostTime:0.38,now:0.38,send:sink)
    #expect(held.status == .waitingForNeutral)
    #expect(output.map { $0.command.value } == [102,0])
    _ = state.receiveScalar(.touchBar,token:id,value:nil,hostTime:0.39,now:0.39,send:sink)
    #expect(state.sourceStates[.touchBar] == .armed)
    _ = state.receiveScalar(.touchBar,token:id,value:0.5,hostTime:0.4,now:0.4,send:sink)
    #expect(output.map { $0.command.value } == [102,0,64])
    _ = state.unbind(.touchBar,token:id,send:sink)
    #expect(state.sourceStates[.touchBar] == nil)
    let newID = try state.bind(.touchBar,now:0.41)
    #expect(newID != id)
    let stale = state.receiveScalar(.touchBar,token:id,value:1,hostTime:0.42,now:0.42,send:sink)
    #expect(stale.status == .ignored)
    #expect(output.map { $0.command.value } == [102,0,64,0])
}

@Test func groupScalarOptInRejectsNotesPedalsAndWrongSignals() throws {
    let profile = scalarGroupProfile()
    #expect(!PerformanceGroupGamepadSession.supports(profile,allowSurfaces:true))
    #expect(PerformanceGroupGamepadSession.supports(profile,allowSurfaces:true,allowScalars:true))
    for target in [SensorDestination(.note,number:60),.init(.sustain)] {
        let invalid = PerformanceGroupProfile(groups:[.init(name:"Unsafe scalar",patch:.init(routes:[
            .init(id:"gate",source:.lid,signal:.angle,destination:target)
        ]))])
        #expect(!PerformanceGroupGamepadSession.supports(invalid,allowScalars:true))
    }
    let wrong = PerformanceGroupProfile(groups:[.init(name:"Wrong signal",patch:.init(routes:[
        .init(id:"wrong",source:.touchBar,signal:.y,destination:.init(.controlChange,number:74))
    ]))])
    #expect(!PerformanceGroupGamepadSession.supports(wrong,allowScalars:true))
}


@Test func groupScalarPostSendExpirySuppressesRemainingControls() throws {
    let group = PerformanceInstrumentGroup(name:"Controls",patch:.init(routes:[
        .init(id:"a",source:.touchBar,signal:.x,destination:.init(.controlChange,number:74)),
        .init(id:"b",source:.touchBar,signal:.x,destination:.init(.controlChange,number:71))
    ]))
    var state = try PerformanceGroupGamepadSession(profile:.init(groups:[group]),allowScalars:true)
    let token = try state.bind(.touchBar,now:1)
    var now = 1.01
    var sent:[PerformanceGroupCommand] = []
    let result = state.receiveScalar(.touchBar,token:token,value:0.8,hostTime:now,now:now,refreshNow:{now},send:{
        sent.append($0)
        if $0.command.value > 0 { now=1.37 }
        return true
    })
    #expect(result.status == .lost && result.reports.contains(where:{ $0.admissionExpired }))
    #expect(sent.count == 2 && sent.first?.command.destination == sent.last?.command.destination)
    #expect(sent.first?.command.value == 102 && sent.last?.command.value == 0)
    #expect(state.sourceStates[.touchBar] == .waitingForNeutral)
}


@Test func groupScalarStalledReleaseCannotRestoreExpiredLowerPriorityOwner() throws {
    let cc1=SensorDestination(.controlChange,number:71)
    let cc2=SensorDestination(.controlChange,number:74)
    let group=PerformanceInstrumentGroup(name:"Two effects",patch:.init(routes:[
        .init(id:"low1",source:.lid,signal:.angle,destination:cc1,priority:0),
        .init(id:"low2",source:.lid,signal:.angle,destination:cc2,priority:0),
        .init(id:"high1",source:.touchBar,signal:.x,destination:cc1,priority:10),
        .init(id:"high2",source:.touchBar,signal:.x,destination:cc2,priority:10)
    ]))
    var state=try PerformanceGroupGamepadSession(profile:.init(groups:[group]),allowScalars:true)
    let low=try state.bind(.lid,now:1),high=try state.bind(.touchBar,now:1)
    _=state.receiveScalar(.lid,token:low,value:0.2,hostTime:1.01,now:1.01,send:{_ in true})
    _=state.receiveScalar(.touchBar,token:high,value:0.8,hostTime:1.2,now:1.2,send:{_ in true})
    var now=1.3
    var sent:[PerformanceGroupCommand]=[]
    let result=state.receiveScalar(.touchBar,token:high,value:nil,hostTime:now,now:now,
                                    refreshNow:{now},send:{
        sent.append($0)
        if $0.command.value==25 { now=1.37 }
        return true
    })
    #expect(result.status == .lost && result.reports.contains(where:{ $0.admissionExpired }))
    #expect(sent.filter { $0.command.value==25 }.count==1)
    #expect(Set(sent.filter { $0.command.value==0 }.map(\.command.destination)) == [cc1,cc2])
    #expect(state.activeSessions==0 && state.pendingCleanup.isEmpty)
}

@Test func groupWatchdogDrainsNewlyExpiredSourcesAfterBlockingNeutralCleanup() throws {
    let a=PerformanceInstrumentGroup(name:"A",patch:.init(routes:[
        .init(id:"a",source:.trackpad,signal:.contact,destination:.init(.note,number:60))
    ]))
    let b=PerformanceInstrumentGroup(name:"B",patch:.init(routes:[
        .init(id:"b",source:.magicMouse,signal:.contact,destination:.init(.note,number:64))
    ]))
    var state=try PerformanceGroupGamepadSession(profile:.init(groups:[a,b]),allowSurfaces:true)
    let x=try state.bind(.trackpad,now:1),y=try state.bind(.magicMouse,now:1)
    _=state.receiveSurface(.trackpad,token:x,x:nil,y:nil,size:nil,hostTime:1,now:1,send:{_ in true})
    _=state.receiveSurface(.magicMouse,token:y,x:nil,y:nil,size:nil,hostTime:1,now:1,send:{_ in true})
    _=state.receiveSurface(.trackpad,token:x,x:0.5,y:0.5,size:0.5,hostTime:1.01,now:1.01,send:{_ in true})
    _=state.receiveSurface(.magicMouse,token:y,x:0.5,y:0.5,size:0.5,hostTime:1.2,now:1.2,send:{_ in true})
    var now=1.37
    var sent:[PerformanceGroupCommand]=[]
    _=state.expire(now:now,refreshNow:{now},send:{
        sent.append($0)
        if $0.groupID==a.id { now=1.56 }
        return true
    })
    #expect(sent.map(\.groupID)==[a.id,b.id] && sent.allSatisfy { $0.command.value==0 })
    #expect(state.activeSessions==0 && state.pendingCleanup.isEmpty)
}
