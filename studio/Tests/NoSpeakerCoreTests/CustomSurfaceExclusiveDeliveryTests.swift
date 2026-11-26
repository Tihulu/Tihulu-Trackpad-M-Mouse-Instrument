import Foundation
import Testing
@testable import NoSpeakerCore

private func deliveryPlan() throws -> CustomSurfaceMixedPlan {
    let layout=try #require(CustomSurfacePadLayout(surface:.trackpad,pads:[
        .init(id:"chord",label:"Chord",x:0,y:0,width:2500,height:10000,assignment:.chord([60,64])),
        .init(id:"note",label:"Note",x:2500,y:0,width:2500,height:10000,assignment:.note(60)),
        .init(id:"sustain",label:"Sustain",x:5000,y:0,width:2500,height:10000,assignment:.helper(.init(.sustain,channel:2))),
        .init(id:"control",label:"Control",x:7500,y:0,width:2500,height:10000,assignment:.helper(.init(.controlChange,channel:2,number:11)))
    ]))
    return try .init(layout:layout,melodicChannel:2)
}
private typealias Contact=CustomSurfaceContactProjection.Contact
private let chord=Contact(id:1,x:0.125,y:0.5,velocity:90)
private let note=Contact(id:2,x:0.375,y:0.5)
private let pedal=Contact(id:3,x:0.625,y:0.5)
private let control=Contact(id:4,x:0.875,y:0.5)
private let n60=SensorDestination(.note,channel:2,number:60)
private let n64=SensorDestination(.note,channel:2,number:64)
private let cc=SensorDestination(.controlChange,channel:2,number:11)
private let sustain=SensorDestination(.sustain,channel:2)

@Test func customPadExclusiveDeliveryOrdersSustainAndPreservesCommonNotes() throws {
    var now:Int64=0
    var wire:[SensorCommand]=[]
    let d=CustomSurfaceExclusiveDelivery(plan:try deliveryPlan(),clock:{now},admitsExclusiveEndpoint:{true},send:{wire.append($0);return true})
    #expect(d.frame([chord],sequence:1,observedAt:0).accepted==0)
    now=1;_=d.frame([],sequence:2,observedAt:1)
    now=2;let active=d.frame([chord,note,pedal,control],sequence:3,observedAt:2)
    #expect(wire==[.init(sustain,value:127),.init(cc,value:64),.init(n60,value:90),.init(n64,value:90)])
    #expect(active.outstanding==Set([sustain,cc,n60,n64]))
    wire=[]
    now=3;_=d.frame([note,pedal],sequence:4,observedAt:3)
    #expect(wire==[.init(n64,value:0),.init(cc,value:127)])
    wire=[]
    now=4;let off=d.frame([],sequence:5,observedAt:4)
    #expect(wire==[.init(n60,value:0),.init(sustain,value:0)])
    #expect(off.outstanding.isEmpty && !off.retired)
}
@Test func customPadExclusiveDeliveryRetainsFailedAttackAndCleanupDebt() throws {
    var now:Int64=0
    var failing=true
    var wire:[SensorCommand]=[]
    let d=CustomSurfaceExclusiveDelivery(plan:try deliveryPlan(),clock:{now},admitsExclusiveEndpoint:{true},send:{
        wire.append($0)
        return !failing || $0.destination != n60
    })
    _=d.frame([],sequence:1,observedAt:0)
    now=1;let failed=d.frame([chord,pedal],sequence:2,observedAt:1)
    #expect(failed.retirement == .sendFailed)
    #expect(failed.pendingCleanup==Set([n60]))
    #expect(wire==[.init(sustain,value:127),.init(n60,value:90),.init(n60,value:0),.init(sustain,value:0)])
    wire=[]
    now=2;#expect(d.frame([chord],sequence:3,observedAt:2).retired)
    #expect(wire.isEmpty)
    failing=false
    #expect(d.retryCleanup().pendingCleanup.isEmpty)
    #expect(wire==[.init(n60,value:0)])
}
@Test func customPadExclusiveDeliveryFencesEachSendAndCleansAfterDeadline() throws {
    var now:Int64=0
    var wire:[SensorCommand]=[]
    let d=CustomSurfaceExclusiveDelivery(plan:try deliveryPlan(),clock:{now},admitsExclusiveEndpoint:{true},send:{
        wire.append($0)
        if $0.destination==sustain && $0.value==127 {now=150_000_001}
        return true
    })
    _=d.frame([],sequence:1,observedAt:0)
    now=1;let failed=d.frame([chord,pedal],sequence:2,observedAt:1)
    #expect(failed.retirement == .expiredOrInvalid)
    #expect(failed.pendingCleanup.isEmpty)
    #expect(wire==[.init(sustain,value:127),.init(sustain,value:0)])
}
@Test func customPadExclusiveDeliveryPollRetiresWithoutFreshAttackAndRequiresAdmission() throws {
    var now:Int64=0
    var allowed=true
    var wire:[SensorCommand]=[]
    let d=CustomSurfaceExclusiveDelivery(plan:try deliveryPlan(),clock:{now},admitsExclusiveEndpoint:{allowed},send:{wire.append($0);return true})
    _=d.frame([],sequence:1,observedAt:0)
    now=1;_=d.frame([note],sequence:2,observedAt:1)
    wire=[]
    now=150_000_000;#expect(!d.poll().retired)
    #expect(wire.isEmpty)
    now=150_000_001;#expect(d.poll().retirement == .expiredOrInvalid)
    #expect(wire==[.init(n60,value:0)])
    allowed=false;wire=[]
    let denied=CustomSurfaceExclusiveDelivery(plan:try deliveryPlan(),clock:{now},admitsExclusiveEndpoint:{allowed},send:{wire.append($0);return true})
    #expect(denied.frame([],sequence:1,observedAt:now).retirement == .admissionDenied)
    #expect(wire.isEmpty)
}
