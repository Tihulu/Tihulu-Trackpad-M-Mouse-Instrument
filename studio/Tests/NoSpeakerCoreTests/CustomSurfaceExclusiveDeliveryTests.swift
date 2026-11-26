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
    let d=CustomSurfaceExclusiveDelivery(plan:try deliveryPlan(),clock:{now},admitsExclusiveEndpoint:{true},ownsCleanupEndpoint:{true},send:{wire.append($0);return true})
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
    let d=CustomSurfaceExclusiveDelivery(plan:try deliveryPlan(),clock:{now},admitsExclusiveEndpoint:{true},ownsCleanupEndpoint:{true},send:{
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
    let d=CustomSurfaceExclusiveDelivery(plan:try deliveryPlan(),clock:{now},admitsExclusiveEndpoint:{true},ownsCleanupEndpoint:{true},send:{
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
    let d=CustomSurfaceExclusiveDelivery(plan:try deliveryPlan(),clock:{now},admitsExclusiveEndpoint:{allowed},ownsCleanupEndpoint:{true},send:{wire.append($0);return true})
    _=d.frame([],sequence:1,observedAt:0)
    now=1;_=d.frame([note],sequence:2,observedAt:1)
    wire=[]
    now=150_000_000;#expect(!d.poll().retired)
    #expect(wire.isEmpty)
    now=150_000_001;#expect(d.poll().retirement == .expiredOrInvalid)
    #expect(wire==[.init(n60,value:0)])
    allowed=false;wire=[]
    let denied=CustomSurfaceExclusiveDelivery(plan:try deliveryPlan(),clock:{now},admitsExclusiveEndpoint:{allowed},ownsCleanupEndpoint:{true},send:{wire.append($0);return true})
    #expect(denied.frame([],sequence:1,observedAt:now).retirement == .admissionDenied)
    #expect(wire.isEmpty)
}

@Test func customPadExclusiveDeliveryLiveRevocationStillCleansPinnedEndpoint() throws {
    var now:Int64=0
    var allowed=true
    var wire:[SensorCommand]=[]
    let d=CustomSurfaceExclusiveDelivery(plan:try deliveryPlan(),clock:{now},admitsExclusiveEndpoint:{allowed},ownsCleanupEndpoint:{true},send:{wire.append($0);return true})
    _=d.frame([],sequence:1,observedAt:0)
    now=1;_=d.frame([note,pedal],sequence:2,observedAt:1)
    allowed=false;wire=[]
    let stopped=d.poll()
    #expect(stopped.retirement == .admissionDenied)
    #expect(stopped.pendingCleanup.isEmpty)
    #expect(wire==[.init(n60,value:0),.init(sustain,value:0)])
}
@Test func customPadExclusiveDeliveryLostEndpointRetainsDebt() throws {
    var now:Int64=0
    var originalPinned=true
    var wire:[SensorCommand]=[]
    let d=CustomSurfaceExclusiveDelivery(plan:try deliveryPlan(),clock:{now},admitsExclusiveEndpoint:{true},ownsCleanupEndpoint:{originalPinned},send:{wire.append($0);return true})
    _=d.frame([],sequence:1,observedAt:0)
    now=1;_=d.frame([chord,pedal],sequence:2,observedAt:1)
    originalPinned=false;wire=[]
    let stopped=d.poll()
    #expect(stopped.retirement == .admissionDenied)
    #expect(stopped.pendingCleanup==Set([n60,n64,sustain]))
    #expect(d.retryCleanup().pendingCleanup==stopped.pendingCleanup)
    #expect(wire.isEmpty)
    // Recovery must prove the original reserved endpoint, not a replacement.
    originalPinned=true
    #expect(d.retryCleanup().pendingCleanup.isEmpty)
    #expect(Set(wire.map(\.destination))==Set([n60,n64,sustain]))
    #expect(wire.count==3)
}
@Test func customPadExclusiveDeliveryChecksOwnershipBeforeEveryCleanupSend() throws {
    var now:Int64=0
    var originalPinned=true
    var wire:[SensorCommand]=[]
    let d=CustomSurfaceExclusiveDelivery(plan:try deliveryPlan(),clock:{now},admitsExclusiveEndpoint:{true},ownsCleanupEndpoint:{originalPinned},send:{
        wire.append($0)
        if $0.value==0 {originalPinned=false}
        return true
    })
    _=d.frame([],sequence:1,observedAt:0)
    now=1;_=d.frame([chord,pedal],sequence:2,observedAt:1)
    wire=[]
    let stopped=d.stop()
    #expect(wire.count==1)
    #expect(stopped.pendingCleanup.count==2)
    #expect(d.retryCleanup().pendingCleanup==stopped.pendingCleanup)
    #expect(wire.count==1)
}
@Test func customPadExclusiveDeliveryNeverArmsWithoutPinnedEndpoint() throws {
    var wire:[SensorCommand]=[]
    let d=CustomSurfaceExclusiveDelivery(plan:try deliveryPlan(),clock:{0},admitsExclusiveEndpoint:{true},ownsCleanupEndpoint:{false},send:{wire.append($0);return true})
    #expect(d.frame([],sequence:1,observedAt:0).retirement == .admissionDenied)
    #expect(d.frame([note],sequence:2,observedAt:0).outstanding.isEmpty)
    #expect(wire.isEmpty)
}

@Test func customPadExclusiveDeliveryRechecksAdmissionAfterIdentityQuery() throws {
    var now:Int64=0
    var allowed=true
    var revokeDuringQuery=false
    var wire:[SensorCommand]=[]
    let d=CustomSurfaceExclusiveDelivery(plan:try deliveryPlan(),clock:{now},
        admitsExclusiveEndpoint:{allowed},ownsCleanupEndpoint:{
            if revokeDuringQuery {allowed=false}
            return true
        },send:{wire.append($0);return true})
    _=d.frame([],sequence:1,observedAt:0)
    now=1;_=d.frame([note],sequence:2,observedAt:1)
    wire=[]
    now=2;revokeDuringQuery=true
    let stopped=d.frame([chord,pedal],sequence:3,observedAt:2)
    #expect(stopped.retirement == .admissionDenied)
    #expect(stopped.pendingCleanup.isEmpty)
    #expect(wire==[.init(n60,value:0)])
}
@Test func customPadExclusiveDeliveryRechecksAdmissionBetweenChordSends() throws {
    var now:Int64=0
    var allowed=true
    var revokeOnNextQuery=false
    var wire:[SensorCommand]=[]
    let d=CustomSurfaceExclusiveDelivery(plan:try deliveryPlan(),clock:{now},
        admitsExclusiveEndpoint:{allowed},ownsCleanupEndpoint:{
            if revokeOnNextQuery {allowed=false}
            return true
        },send:{
            wire.append($0)
            if $0.destination==n60 && $0.value>0 {revokeOnNextQuery=true}
            return true
        })
    _=d.frame([],sequence:1,observedAt:0)
    now=1
    let stopped=d.frame([chord],sequence:2,observedAt:1)
    #expect(stopped.retirement == .admissionDenied)
    #expect(stopped.pendingCleanup.isEmpty)
    #expect(wire==[.init(n60,value:90),.init(n60,value:0)])
}

@Test func customPadExclusiveDeliveryHoldsOneNoteAcrossFiveSecondsOfFreshFrames() throws {
    var now:Int64=0
    var wire:[SensorCommand]=[]
    let d=CustomSurfaceExclusiveDelivery(plan:try deliveryPlan(),permitsNeutralSilence:true,clock:{now},
        admitsExclusiveEndpoint:{true},ownsCleanupEndpoint:{true},send:{wire.append($0);return true})
    _=d.frame([],sequence:1,observedAt:0)
    // Idle silence is allowed only after a genuine neutral frame.
    now=1_000_000_000
    #expect(!d.poll().retired)
    for index in 0...50 {
        now=1_000_000_001+Int64(index)*100_000_000
        let report=d.frame([note],sequence:UInt64(index+2),observedAt:now)
        #expect(!report.retired && report.outstanding==Set([n60]))
    }
    #expect(wire==[.init(n60,value:100)])
    now+=100_000_000
    let off=d.frame([],sequence:53,observedAt:now)
    #expect(!off.retired && off.outstanding.isEmpty)
    #expect(wire==[.init(n60,value:100),.init(n60,value:0)])
    now+=1_000_000_000
    #expect(!d.poll().retired)
}
@Test func customPadExclusiveDeliveryDoesNotResumeAfterOccupiedCadenceLoss() throws {
    var now:Int64=0
    var wire:[SensorCommand]=[]
    let d=CustomSurfaceExclusiveDelivery(plan:try deliveryPlan(),permitsNeutralSilence:true,clock:{now},
        admitsExclusiveEndpoint:{true},ownsCleanupEndpoint:{true},send:{wire.append($0);return true})
    _=d.frame([],sequence:1,observedAt:0)
    now=1
    _=d.frame([note,pedal],sequence:2,observedAt:now)
    now=150_000_001
    #expect(d.poll().retirement == .expiredOrInvalid)
    #expect(wire==[.init(sustain,value:127),.init(n60,value:100),.init(n60,value:0),.init(sustain,value:0)])
    now+=1
    #expect(d.frame([],sequence:3,observedAt:now).retired)
    now+=1
    #expect(d.frame([note],sequence:4,observedAt:now).retired)
    #expect(wire.count==4)
}
