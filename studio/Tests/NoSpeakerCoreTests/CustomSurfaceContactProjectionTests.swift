import Foundation
import Testing
@testable import NoSpeakerCore

private typealias Projection=CustomSurfaceContactProjection
private func mixedPadProjection() throws -> Projection {
    let layout=try #require(CustomSurfacePadLayout(surface:.trackpad,pads:[
        .init(id:"chord",label:"Chord",x:0,y:0,width:4000,height:10000,assignment:.chord([60,64,67])),
        .init(id:"xy",label:"XY",x:5000,y:0,width:5000,height:10000,assignment:.xy(.init(.controlChange,number:1),.init(.pitchBend)))
    ]))
    return Projection(layout:layout)
}
@Test func customSurfaceContactsNeedNeutralAndStayBoundToOrigin() throws {
    var p=try mixedPadProjection()
    let chord=Projection.Contact(id:1,x:0.2,y:0.5)
    let xy=Projection.Contact(id:2,x:0.75,y:0.25,velocity:90)
    #expect(p.frame([chord],sequence:1,observedAt:1,now:1).intents.isEmpty)
    #expect(p.frame([],sequence:2,observedAt:2,now:2).intents.isEmpty)
    let active=p.frame([xy,chord],sequence:3,observedAt:3,now:3)
    #expect(active.intents.map(\.padID)==["chord","xy"])
    #expect(active.intents[1].x==0.5 && active.intents[1].y==0.75)
    let moved=p.frame([.init(id:1,x:0.9,y:0.9),.init(id:2,x:0.2,y:0.5)],sequence:4,observedAt:4,now:4)
    #expect(moved.intents.map(\.padID)==["chord"])
    #expect(moved.intents.first?.velocity==100)
    let returned=p.frame([xy],sequence:5,observedAt:5,now:5)
    #expect(returned.intents.isEmpty)
    #expect(p.frame([],sequence:6,observedAt:6,now:6).intents.isEmpty)
    #expect(p.frame([xy],sequence:7,observedAt:7,now:7).intents.count==1)
}
@Test func customSurfaceContactsDoNotAttackFromGapAndRetireOnInvalidFrames() throws {
    var p=try mixedPadProjection()
    _=p.frame([],sequence:1,observedAt:1,now:1)
    #expect(p.frame([.init(id:1,x:0.45,y:0.5)],sequence:2,observedAt:2,now:2).intents.isEmpty)
    #expect(p.frame([.init(id:1,x:0.2,y:0.5)],sequence:3,observedAt:3,now:3).intents.isEmpty)
    let duplicate=Projection.Contact(id:1,x:0.2,y:0.5)
    let rejected=p.frame([duplicate,duplicate],sequence:4,observedAt:4,now:4)
    #expect(rejected.retired && rejected.intents.isEmpty)
    #expect(p.frame([],sequence:5,observedAt:5,now:5).retired)
}
@Test func customSurfaceContactWatchdogAndDelayedDrainCannotRearm() throws {
    var p=try mixedPadProjection()
    let touch=Projection.Contact(id:1,x:0.2,y:0.5)
    _=p.frame([],sequence:1,observedAt:0,now:0)
    #expect(p.frame([touch],sequence:2,observedAt:10,now:10).intents.count==1)
    let before=p.poll(now:150_000_009)
    #expect(!before.retired)
    let delayed=p.frame([touch],sequence:3,observedAt:150_000_000,now:150_000_010)
    #expect(delayed.retired && delayed.intents.isEmpty)
    var q=try mixedPadProjection()
    _=q.frame([],sequence:1,observedAt:0,now:0)
    _=q.frame([touch],sequence:2,observedAt:1,now:1)
    #expect(q.poll(now:150_000_001).retired)
    #expect(q.frame([],sequence:3,observedAt:150_000_002,now:150_000_002).retired)
}

@Test func customSurfaceSnapshotCarriesOriginalObservationAndFrozenLayout() throws {
    var p=try mixedPadProjection()
    let neutral=p.frame([],sequence:1,observedAt:10,now:20)
    #expect(neutral.observedAt==10)
    #expect(neutral.layout==p.layout)
    let played=p.frame([.init(id:1,x:0.2,y:0.5)],sequence:2,observedAt:30,now:40)
    #expect(played.observedAt==30)
    #expect(!p.poll(now:100).retired)
    let retired=p.retire()
    #expect(retired.observedAt==nil && retired.intents.isEmpty && retired.retired)
}
