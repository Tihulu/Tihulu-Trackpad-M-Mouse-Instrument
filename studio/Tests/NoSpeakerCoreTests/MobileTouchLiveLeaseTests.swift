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

private func mask(_ action:MobileAirSendGate.Action)throws->Int {
    guard case .send(let data)=action else{throw RemoteTouchError.invalidFrame}
    return try RemoteTouchFrame.read(data).mask ?? 0
}
@Test func touchLeaseAndSendGateSustainStationaryNoteThenRelease() throws {
    var lease=try #require(MobileTouchLiveLease(authorized:3,armedAt:touchMS(20)))
    var gate=try #require(MobileAirSendGate(lane:.keys(authorized:3),initialSequence:0))
    _=gate.begin(now:0);_=gate.acknowledge("accepted",now:touchMS(20))
    let event=lease.event(.began,contacts:[.init(id:0,x:0)],now:touchMS(30),ownerActive:true)
    let down=try #require(event)
    #expect(try mask(gate.offer(down.output,observedAt:down.ownerAt,now:down.ownerAt))==1)
    _=gate.acknowledge("accepted",now:touchMS(35))
    for time:Int64 in [80,130,180,230,280] {
        let sample=lease.pulse(now:touchMS(time),ownerActive:true)
        let pulse=try #require(sample)
        #expect(try mask(gate.offer(pulse.output,observedAt:pulse.ownerAt,now:pulse.ownerAt))==1)
        #expect(gate.acknowledge("accepted",now:touchMS(time+5)) == .wait)
    }
    let release=lease.event(.ended,contacts:[],now:touchMS(295),ownerActive:true)
    let up=try #require(release)
    #expect(try mask(gate.offer(up.output,observedAt:up.ownerAt,now:up.ownerAt))==0)
    #expect(gate.acknowledge("accepted",now:touchMS(300)) == .wait)
}
@Test func touchLeaseAndIndependentSenderExpireWithoutViewPulse() throws {
    var lease=try #require(MobileTouchLiveLease(authorized:1,armedAt:touchMS(20)))
    var gate=try #require(MobileAirSendGate(lane:.keys(authorized:1),initialSequence:0))
    _=gate.begin(now:0);_=gate.acknowledge("accepted",now:touchMS(20))
    let event=lease.event(.began,contacts:[.init(id:0,x:0)],now:touchMS(30),ownerActive:true)
    let down=try #require(event)
    _=gate.offer(down.output,observedAt:down.ownerAt,now:down.ownerAt)
    _=gate.acknowledge("accepted",now:touchMS(35))
    #expect(try mask(gate.poll(now:touchMS(180)))==0)
    #expect(lease.pulse(now:touchMS(180),ownerActive:true)==nil)
    _=gate.acknowledge("accepted",now:touchMS(185))
    #expect(lease.event(.began,contacts:[.init(id:1,x:0)],now:touchMS(190),ownerActive:true)==nil)
}
