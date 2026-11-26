import Testing
@testable import NoSpeakerCore

private func touchMS(_ n:Int64)->Int64{n*1_000_000}

@Test func touchLeaseStationaryOwnerPulseAndActualRelease() throws {
    var l=try #require(MobileTouchLiveLease(authorized:3,armedAt:0))
    #expect(l.event(.began,contacts:[.init(id:0,x:0)],now:touchMS(1),ownerActive:true)?.output.keys==1)
    for i in [50,100,150,200,250] {
        let pulse=l.pulse(now:touchMS(Int64(i)),ownerActive:true)
        #expect(pulse?.output.keys==1)
        #expect(pulse?.ownerAt==touchMS(Int64(i)))
    }
    #expect(l.event(.ended,contacts:[],now:touchMS(251),ownerActive:true)?.output.keys==0)
    #expect(l.pulse(now:touchMS(300),ownerActive:true)?.output.keys==0)
}
@Test func touchLeaseMissedPulseNeverRearmsOldTouch() throws {
    var l=try #require(MobileTouchLiveLease(authorized:1,armedAt:0))
    _=l.event(.began,contacts:[.init(id:0,x:0)],now:touchMS(1),ownerActive:true)
    #expect(l.pulse(now:touchMS(150),ownerActive:true)?.output.keys==1)
    #expect(l.pulse(now:touchMS(300),ownerActive:true)==nil)
    #expect(l.retired && l.output.keys==0)
    #expect(l.event(.began,contacts:[.init(id:1,x:0)],now:touchMS(301),ownerActive:true)==nil)
}
@Test func touchLeaseFocusCancelAndRollbackAreTerminal() throws {
    for at in [touchMS(1),touchMS(0)] {
        var l=try #require(MobileTouchLiveLease(authorized:1,armedAt:0))
        _=l.event(.began,contacts:[.init(id:0,x:0)],now:touchMS(1),ownerActive:true)
        #expect(l.pulse(now:at,ownerActive:true)==nil)
        #expect(l.retired)
    }
    var l=try #require(MobileTouchLiveLease(authorized:1,armedAt:0))
    _=l.event(.began,contacts:[.init(id:0,x:0)],now:1,ownerActive:true)
    #expect(l.pulse(now:2,ownerActive:false)==nil)
    #expect(l.pulse(now:3,ownerActive:true)==nil)
    var c=try #require(MobileTouchLiveLease(authorized:1,armedAt:0))
    _=c.event(.began,contacts:[.init(id:0,x:0)],now:1,ownerActive:true)
    #expect(c.event(.cancelled,contacts:[],now:2,ownerActive:true)==nil)
    #expect(c.output.keys==0 && c.retired)
}
@Test func touchLeaseNeutralOwnerGapAlsoRequiresExplicitRearm() throws {
    var l=try #require(MobileTouchLiveLease(authorized:1,armedAt:0))
    #expect(l.pulse(now:touchMS(150),ownerActive:true)==nil)
    #expect(l.retired)
    #expect(MobileTouchLiveLease(authorized:0,armedAt:0)==nil)
    #expect(MobileTouchLiveLease(authorized:1,armedAt:-1)==nil)
}
