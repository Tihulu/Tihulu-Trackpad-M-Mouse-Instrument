import Foundation
import Testing
@testable import NoSpeakerCore

private func observed(_ x:Double=0.5,open:Bool=true,fingers:Int?=nil) -> MobileAirObservation {
    .init(sample:AirHandSample.debugSample(x:x,y:0.5,aperture:open ? 0.6 : 0.1),fingers:fingers,confidence:1)
}

@Test func mobileCaptureRoleRequiresDistinctHandsAndNeutralAfterLoss() throws {
    #expect(MobileAirCaptureProjection(mode:.chords,keys:145) == nil)
    var p=try #require(MobileAirCaptureProjection(mode:.chords,keys:145,role:.right))
    var t=0.0
    func step(_ count:Int?,open:Bool=true,selector:Bool=true) -> Int {
        t += 0.07
        let right=observed(open:open)
        let left=selector ? observed(fingers:count) : nil
        return p.receive(.init(single:left == nil ? right : nil,left:left,right:right,time:t),now:t).keys
    }
    _=step(0);_=step(0)
    for _ in 0..<4 { _=step(1) }
    #expect(step(1,open:false)==145)
    #expect(step(nil,open:false,selector:false)==0)
    for _ in 0..<5 { #expect(step(1,open:false)==0) }
    _=step(0);_=step(0)
    for _ in 0..<4 { _=step(1) }
    #expect(step(1,open:false)==145)
    #expect(p.expire(now:t+0.16)==MobileAirOutput())
}

@Test func mobileCaptureOrientationAndWatchdogReleaseWithoutFrames() throws {
    var p=try #require(MobileAirCaptureProjection(mode:.horizontal,keys:0,role:.left,orientation:.upsideDown))
    let hand=observed(0.25)
    #expect(p.receive(.init(left:hand,time:1),now:1).level==nil)
    #expect(p.receive(.init(left:hand,time:1.05),now:1.05).level==0.75)
    #expect(p.expire(now:1.1)==nil)
    #expect(p.expire(now:1.21)==MobileAirOutput())
    #expect(p.receive(.init(right:hand,time:1.22),now:1.22).level==nil)
    #expect(p.receive(.init(left:hand,time:1.27),now:1.27).level==nil)
    #expect(p.receive(.init(left:hand,time:1.32),now:1.32).level==0.75)
}

@Test func mobilePinchToggleClearsOnLossAndRequiresOpenToRearm() throws {
    var p=try #require(MobileAirInstrument(mode:.toggleHelper,keys:0))
    var t=0.0
    func step(_ open:Bool?) -> Double? {
        t += 0.05
        return p.frame(hand:open.map { observed(open:$0).sample } ?? nil,at:t,now:t).level
    }
    #expect(step(false)==nil)
    #expect(step(false)==0)
    #expect(step(true)==0)
    #expect(step(false)==1)
    #expect(step(true)==1)
    #expect(step(false)==0)
    #expect(step(nil)==nil)
    #expect(step(false)==nil)
    #expect(step(false)==0)
}

@Test func mobileAirWireOnlyEncodesAuthorizedLogicalLanes() throws {
    let keys=MobileAirWireLane.keys(authorized:145)
    let note=try RemoteTouchFrame.read(keys.encode(.init(keys:145),sequence:1))
    #expect(note.mask==145 && note.kind == .pianoKeys)
    #expect(throws:RemoteTouchError.invalidFrame) { try keys.encode(.init(keys:2),sequence:2) }
    #expect(throws:RemoteTouchError.invalidFrame) { try keys.encode(.init(keys:1,level:0),sequence:2) }
    let helper=MobileAirWireLane.helper(index:2,authorized:4)
    let activeZero=try RemoteTouchFrame.read(helper.encode(.init(level:0),sequence:3))
    let release=try RemoteTouchFrame.read(helper.encode(.init(),sequence:4))
    #expect(activeZero.mask==4 && release.mask==0)
    #expect(throws:RemoteTouchError.invalidFrame) { try helper.encode(.init(level:.nan),sequence:5) }
    #expect(throws:RemoteTouchError.invalidFrame) { try MobileAirWireLane.helper(index:3,authorized:8).encode(.init(level:1),sequence:6) }
}


@Test func androidLogicalWireFixturesAreAcceptedByHostParser() throws {
    let keys = try RemoteTouchFrame.read(Data(#"{"kind":"pianoKeys","version":5,"sequence":1,"mask":145}"#.utf8))
    let zero = try RemoteTouchFrame.read(Data(#"{"kind":"pedalboard","version":6,"sequence":3,"mask":4,"levels":[0.0,0.0,0.0,0.0,0.0,0.0]}"#.utf8))
    let release = try RemoteTouchFrame.read(Data(#"{"kind":"pedalboard","version":6,"sequence":4,"mask":0,"levels":[0.0,0.0,0.0,0.0,0.0,0.0]}"#.utf8))
    #expect(keys.mask == 145 && keys.kind == .pianoKeys)
    #expect(zero.mask == 4 && zero.kind == .pedalboard)
    #expect(release.mask == 0 && release.kind == .pedalboard)
}
