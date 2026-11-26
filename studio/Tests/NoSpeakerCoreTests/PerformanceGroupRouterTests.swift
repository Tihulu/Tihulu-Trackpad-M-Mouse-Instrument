import Foundation
import Testing
@testable import NoSpeakerCore

private func groupRoute(_ id: String, _ source: SensorSource, _ signal: SensorSignal,
                        _ target: SensorDestination) -> SensorMapping {
    .init(id:id,source:source,signal:signal,destination:target)
}

@Test func performanceGroupsSameChannelAndNoteRemainIndependent() throws {
    let target = SensorDestination(.note,channel:0,number:60)
    let a = PerformanceInstrumentGroup(name:"A",patch:.init(routes:[groupRoute("a",.trackpad,.contact,target)]))
    let b = PerformanceInstrumentGroup(name:"B",patch:.init(routes:[groupRoute("b",.magicMouse,.contact,target)]))
    var router = try PerformanceGroupRouter(profile:.init(groups:[a,b]))
    let x = try router.connect(.trackpad,now:1)
    let y = try router.connect(.magicMouse,now:1)
    let first = router.frame(lease:x,sequence:1,now:1,values:[.contact:1])
    let second = router.frame(lease:y,sequence:1,now:1,values:[.contact:1])
    #expect(first == [.init(groupID:a.id,command:.init(target,value:100))])
    #expect(second == [.init(groupID:b.id,command:.init(target,value:100))])
    let stop = router.stopGroup(a.id)
    #expect(stop == [.init(groupID:a.id,command:.init(target,value:0))])
    #expect(router.sessionCount == 1)
    let stale = router.frame(lease:x,sequence:2,now:1.1,values:[.contact:1])
    #expect(stale.isEmpty)
    let off = router.disconnect(y)
    #expect(off == [.init(groupID:b.id,command:.init(target,value:0))])
}

@Test func performanceGroupsLayeringRequiresConsentAndStopIsScoped() throws {
    let target = SensorDestination(.note,number:60)
    let a = PerformanceInstrumentGroup(name:"A",patch:.init(routes:[groupRoute("a",.gamepad1,.padA,target)]))
    let b = PerformanceInstrumentGroup(name:"B",patch:.init(routes:[groupRoute("b",.gamepad1,.padA,target)]))
    let profile = PerformanceGroupProfile(groups:[a,b])
    #expect(throws: PerformanceGroupRouterError.layeringConsentRequired) {
        try PerformanceGroupRouter(profile:profile)
    }
    var router = try PerformanceGroupRouter(profile:profile,allowLayering:true)
    let id = try router.connect(.gamepad1,now:1)
    let on = router.frame(lease:id,sequence:1,now:1,values:[.padA:1])
    #expect(Set(on.map(\.groupID)) == [a.id,b.id])
    #expect(on.count == 2)
    let stop = router.stopGroup(a.id)
    #expect(stop == [.init(groupID:a.id,command:.init(target,value:0))])
    #expect(router.sessionCount == 1)
    let up = router.frame(lease:id,sequence:2,now:1.1,values:[:],releasing:[.padA])
    #expect(up == [.init(groupID:b.id,command:.init(target,value:0))])
    let onAgain = router.frame(lease:id,sequence:3,now:1.2,values:[.padA:1])
    #expect(onAgain == [.init(groupID:b.id,command:.init(target,value:100))])
    let all = router.panic()
    #expect(all == [.init(groupID:b.id,command:.init(target,value:0))])
    #expect(router.retired && router.sessionCount == 0 && router.groupCount == 0)
    #expect(throws: PerformanceGroupRouterError.retired) { try router.connect(.gamepad1,now:2) }
}

@Test func performanceGroupsHelpersSharePedalWithinGroupNotAcrossPorts() throws {
    let pedal = SensorDestination(.sustain)
    let note = SensorDestination(.note,number:60)
    let a = PerformanceInstrumentGroup(name:"A",patch:.init(routes:[
        groupRoute("note",.trackpad,.contact,note),
        groupRoute("pedalA",.trackpad,.pressure,pedal),
        groupRoute("pedalB",.gamepad1,.padRT,pedal)
    ]))
    let b = PerformanceInstrumentGroup(name:"B",patch:.init(routes:[
        groupRoute("pedalC",.gamepad2,.padRT,pedal)
    ]))
    var router = try PerformanceGroupRouter(profile:.init(groups:[a,b]))
    let x = try router.connect(.trackpad,now:1)
    let y = try router.connect(.gamepad1,now:1)
    let z = try router.connect(.gamepad2,now:1)
    let on = router.frame(lease:x,sequence:1,now:1,values:[.contact:1,.pressure:1])
    #expect(on.count == 2 && on.allSatisfy { $0.groupID == a.id })
    let second = router.frame(lease:y,sequence:1,now:1,values:[.padRT:1])
    #expect(second.isEmpty)
    let other = router.frame(lease:z,sequence:1,now:1,values:[.padRT:1])
    #expect(other == [.init(groupID:b.id,command:.init(pedal,value:127))])
    let release = router.disconnect(x)
    #expect(release == [.init(groupID:a.id,command:.init(note,value:0))])
    let releaseHelper = router.disconnect(y)
    #expect(releaseHelper == [.init(groupID:a.id,command:.init(pedal,value:0))])
    let releaseOther = router.disconnect(z)
    #expect(releaseOther == [.init(groupID:b.id,command:.init(pedal,value:0))])
}

@Test func performanceGroupsRejectInvalidFramesWithoutConsumingSequence() throws {
    let target = SensorDestination(.note,number:60)
    let a = PerformanceInstrumentGroup(name:"A",patch:.init(routes:[groupRoute("a",.trackpad,.contact,target)]))
    var router = try PerformanceGroupRouter(profile:.init(groups:[a]))
    let id = try router.connect(.trackpad,now:1)
    let invalid = router.frame(lease:id,sequence:1,now:1,values:[.contact:Double.nan])
    #expect(invalid.isEmpty)
    let overlap = router.frame(lease:id,sequence:1,now:1,values:[.contact:1],releasing:[.contact])
    #expect(overlap.isEmpty)
    let overflow = router.frame(lease:id,sequence:UInt64.max,now:1,values:[.contact:1])
    #expect(overflow.isEmpty)
    let accepted = router.frame(lease:id,sequence:1,now:1,values:[.contact:1])
    #expect(accepted == [.init(groupID:a.id,command:.init(target,value:100))])
    let duplicate = router.frame(lease:id,sequence:1,now:1.1,values:[:],releasing:[.contact])
    #expect(duplicate.isEmpty)
    let backward = router.frame(lease:id,sequence:2,now:0.9,values:[:],releasing:[.contact])
    #expect(backward.isEmpty)
    let expiry = router.expire(now:2,timeout:0.35)
    #expect(expiry == [.init(groupID:a.id,command:.init(target,value:0))])
    let stale = router.frame(lease:id,sequence:3,now:2,values:[.contact:1])
    #expect(stale.isEmpty)
}

@Test func performanceGroupsExpireAllOwnersWithoutRestoringDepartingCC() throws {
    let target = SensorDestination(.controlChange,number:74)
    let a = PerformanceInstrumentGroup(name:"A",patch:.init(routes:[
        .init(id:"high",source:.trackpad,signal:.x,destination:target,priority:10),
        .init(id:"low",source:.magicMouse,signal:.x,destination:target,priority:0)
    ]))
    var router = try PerformanceGroupRouter(profile:.init(groups:[a]))
    let x = try router.connect(.trackpad,now:1)
    let y = try router.connect(.magicMouse,now:1)
    _ = router.frame(lease:x,sequence:1,now:1,values:[.x:0.8])
    _ = router.frame(lease:y,sequence:1,now:1,values:[.x:0.3])
    let expired = router.expire(now:2,timeout:0.35)
    #expect(expired == [.init(groupID:a.id,command:.init(target,value:0))])
    #expect(router.sessionCount == 0)
}

@Test func performanceGroupsGlobalSessionBudgetAndUnmappedSource() throws {
    let a = PerformanceInstrumentGroup(name:"A",patch:.starter)
    var router = try PerformanceGroupRouter(profile:.init(groups:[a]))
    #expect(throws: PerformanceGroupRouterError.noRoute) { try router.connect(.gamepad4,now:1) }
    for _ in 0..<PerformanceGroupRouter.maxSessions { _ = try router.connect(.trackpad,now:1) }
    #expect(router.sessionCount == PerformanceGroupRouter.maxSessions)
    #expect(throws: PerformanceGroupRouterError.sessionLimit) { try router.connect(.magicMouse,now:1) }
    let stopped = router.panic()
    #expect(stopped.isEmpty && router.sessionCount == 0)
}


@Test func groupSnapshotSustainEdgesFollowSameOrderingAsBuilder() throws {
    let note=SensorDestination(.note,number:60)
    let pedal=SensorDestination(.sustain)
    let group=PerformanceInstrumentGroup(name:"Lead",patch:.init(routes:[
        groupRoute("note",.gamepad1,.padA,note),
        groupRoute("pedal",.gamepad1,.padRT,pedal)
    ]))
    var router=try PerformanceGroupRouter(profile:.init(groups:[group]))
    let lease=try router.connect(.gamepad1,now:1)
    let attack=router.frame(lease:lease,sequence:1,now:1,values:[.padA:1])
    #expect(attack.map(\.command)==[.init(note,value:100)])
    let engage=router.frame(lease:lease,sequence:2,now:1.1,values:[.padRT:1],releasing:[.padA])
    #expect(engage.map(\.command)==[.init(pedal,value:127),.init(note,value:0)])
    let release=router.frame(lease:lease,sequence:3,now:1.2,values:[.padA:1],releasing:[.padRT])
    #expect(release.map(\.command)==[.init(note,value:100),.init(pedal,value:0)])
    let stop=router.panic()
    #expect(stop.map(\.command)==[.init(note,value:0)])
}
