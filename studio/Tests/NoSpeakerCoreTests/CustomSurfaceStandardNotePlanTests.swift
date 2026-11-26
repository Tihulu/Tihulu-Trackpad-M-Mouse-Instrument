import Foundation
import Testing
@testable import NoSpeakerCore

@Test func customSurfaceNotePlanSharesGatesAndReleasesOnlyItsOwners() throws {
    let layout=try #require(CustomSurfacePadLayout(surface:.magicMouse,pads:[
        .init(id:"chord",label:"Chord",x:0,y:0,width:3000,height:10000,assignment:.chord([60,64,67])),
        .init(id:"note",label:"Note",x:3000,y:0,width:3000,height:10000,assignment:.note(60)),
        .init(id:"drum",label:"Drum",x:6000,y:0,width:4000,height:10000,assignment:.drum(36))
    ]))
    let plan=try #require(CustomSurfaceStandardNotePlan(layout:layout,melodicChannel:2))
    #expect(plan.isComplete)
    #expect(CustomSurfaceStandardNotePlan(layout:layout,melodicChannel:9)==nil)
    var p=CustomSurfaceContactProjection(layout:layout)
    _=p.frame([],sequence:1,observedAt:1,now:1)
    let a=CustomSurfaceContactProjection.Contact(id:1,x:0.1,y:0.5,velocity:90)
    let b=CustomSurfaceContactProjection.Contact(id:2,x:0.4,y:0.5)
    let c=CustomSurfaceContactProjection.Contact(id:3,x:0.8,y:0.5)
    let notes=try #require(plan.notes(for:p.frame([a,b,c],sequence:2,observedAt:2,now:2)))
    struct Owner:Hashable {let contact:Int;let target:SensorDestination}
    var ledger=LegacyNoteOwners<Owner>()
    var gates=PhysicalChordGates<Int>()
    let external=SensorDestination(.note,channel:2,number:60)
    _=ledger.press(.init(contact:999,target:external),channel:2,note:60,velocity:110)
    let attacks=gates.reconcile(notes.desired,velocity:notes.velocities,ledger:&ledger,owner:{.init(contact:$0,target:$1)})
    #expect(attacks.count==3)
    #expect(attacks.contains(.init(.init(.note,channel:9,number:36),value:100)))
    #expect(!attacks.contains(where:{$0.destination==external}))
    let released=try #require(plan.notes(for:p.retire()))
    let offs=gates.reconcile(released.desired,velocity:released.velocities,ledger:&ledger,owner:{.init(contact:$0,target:$1)})
    #expect(offs.count==3 && offs.allSatisfy{$0.value==0})
    #expect(ledger.active==Set([external]))
}
@Test func customSurfaceStandardPlanRefusesTunedOrHelperFallback() throws {
    let layout=try #require(CustomSurfacePadLayout(surface:.trackpad,pads:[
        .init(id:"degree",label:"Degree",x:0,y:0,width:5000,height:10000,assignment:.degree(-2)),
        .init(id:"helper",label:"Helper",x:5000,y:0,width:5000,height:10000,assignment:.helper(.init(.sustain)))
    ]))
    let plan=try #require(CustomSurfaceStandardNotePlan(layout:layout,melodicChannel:0))
    #expect(!plan.isComplete)
    #expect(plan.unsupportedPadIDs==Set(["degree","helper"]))
    var p=CustomSurfaceContactProjection(layout:layout)
    _=p.frame([],sequence:1,observedAt:1,now:1)
    let snapshot=p.frame([.init(id:1,x:0.1,y:0.5)],sequence:2,observedAt:2,now:2)
    #expect(plan.notes(for:snapshot)==nil)
}
