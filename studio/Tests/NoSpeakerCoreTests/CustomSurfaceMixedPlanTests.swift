import Foundation
import Testing
@testable import NoSpeakerCore

private typealias Mixed=CustomSurfaceMixedPlan
private func mixedLayout(_ assignments:[CustomSurfacePadLayout.Assignment]) throws -> CustomSurfacePadLayout {
    let count=assignments.count
    let pads=assignments.enumerated().map { i,a in
        CustomSurfacePadLayout.Pad(id:"p"+String(i),label:"Pad",x:i*10000/count,y:0,
            width:(i+1)*10000/count-i*10000/count,height:10000,assignment:a)
    }
    return try #require(CustomSurfacePadLayout(surface:.trackpad,pads:pads))
}
@Test func customSurfaceMixedPlanProjectsNotesSustainAndXYTogether() throws {
    let cc=SensorDestination(.controlChange,channel:2,number:11)
    let bend=SensorDestination(.pitchBend,channel:2)
    let layout=try mixedLayout([.note(60),.helper(.init(.sustain,channel:2)),.xy(cc,bend),.drum(36)])
    let plan=try Mixed(layout:layout,melodicChannel:2)
    var projection=CustomSurfaceContactProjection(layout:layout)
    _=projection.frame([],sequence:1,observedAt:1,now:1)
    let contacts:[CustomSurfaceContactProjection.Contact]=[
        .init(id:1,x:0.125,y:0.5),.init(id:2,x:0.375,y:0.5),
        .init(id:3,x:0.625,y:0.5),.init(id:4,x:0.875,y:0.5),
        .init(id:5,x:0.7,y:0.1)]
    let active=try #require(plan.output(for:projection.frame(contacts,sequence:2,observedAt:2,now:2)))
    #expect(active.notes.desired[1]==Set([.init(.note,channel:2,number:60)]))
    #expect(active.notes.desired[4]==Set([.init(.note,channel:9,number:36)]))
    #expect(active.sustainChannels==Set([2]))
    #expect(active.continuous[cc] == .init(64,neutral:127))
    #expect(active.continuous[bend] == .init(8192,neutral:8192))
    var continuous=LegacyContinuousOwners()
    _=continuous.set(.touch,target:cc,value:.init(90,neutral:127))
    _=continuous.replace(.helper,values:active.continuous)
    var sustain=LegacySustainOwners()
    _=sustain.replace(.touch,channels:[2])
    _=sustain.replace(.helper,channels:active.sustainChannels)
    let off=try #require(plan.output(for:projection.retire()))
    #expect(off.notes.desired.isEmpty && off.continuous.isEmpty && off.sustainChannels.isEmpty)
    #expect(continuous.replace(.helper,values:off.continuous).allSatisfy{$0.target != cc})
    #expect(continuous.values(for:.touch)[cc]?.value==90)
    #expect(sustain.replace(.helper,channels:off.sustainChannels).isEmpty)
    #expect(sustain.active==Set([2]))
}
@Test func customSurfaceMixedPlanRejectsAmbiguousAndUnsupportedLayouts() throws {
    let cc=SensorDestination(.controlChange,number:71)
    let duplicate=try mixedLayout([.helper(cc),.xy(cc,.init(.pitchBend))])
    #expect(throws:Mixed.Failure.duplicateContinuousTarget(cc)){try Mixed(layout:duplicate,melodicChannel:0)}
    let degree=try mixedLayout([.degree(2)])
    #expect(throws:Mixed.Failure.unsupportedPad("p0")){try Mixed(layout:degree,melodicChannel:0)}
    let switchPad=try mixedLayout([.helper(.init(.controlChange,number:65))])
    #expect(throws:Mixed.Failure.unsupportedPad("p0")){try Mixed(layout:switchPad,melodicChannel:0)}
    let notes=try mixedLayout([.note(60),.drum(36)])
    #expect(throws:Mixed.Failure.channelConflict){try Mixed(layout:notes,melodicChannel:9)}
    let other=try mixedLayout([.note(61),.drum(36)])
    let plan=try Mixed(layout:notes,melodicChannel:0)
    var projection=CustomSurfaceContactProjection(layout:other)
    #expect(plan.output(for:projection.frame([],sequence:1,observedAt:1,now:1))==nil)
}

@Test func customSurfaceMixedPlanListsAllIdleAndActiveDestinations() throws {
    let cc=SensorDestination(.controlChange,channel:4,number:74)
    let bend=SensorDestination(.pitchBend,channel:5)
    let pedal=SensorDestination(.sustain,channel:2)
    let layout=try mixedLayout([.chord([60,64]),.note(60),.drum(36),.helper(pedal),.xy(cc,bend)])
    let plan=try Mixed(layout:layout,melodicChannel:2)
    #expect(plan.destinations==Set([.init(.note,channel:2,number:60),.init(.note,channel:2,number:64),
        .init(.note,channel:9,number:36),pedal,cc,bend]))
    var projection=CustomSurfaceContactProjection(layout:layout)
    let neutral=try #require(plan.output(for:projection.frame([],sequence:1,observedAt:1,now:1)))
    #expect(neutral.notes.desired.isEmpty && neutral.continuous.isEmpty && neutral.sustainChannels.isEmpty)
    #expect(plan.destinations.count==6)
}
