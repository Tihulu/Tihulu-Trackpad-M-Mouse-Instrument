import Testing
@testable import NoSpeakerCore

@Test func midiObservationHasExactHalfOpenDeadlineEvenIfOwnerStalls() {
    let counter=BoundedMIDIObservation()
    counter.record(packets:9,now:100)
    let started=counter.begin(now:100,seconds:1)
    #expect(started)
    counter.record(packets:2,now:100)
    counter.record(packets:3,now:1_000_000_099)
    counter.record(packets:100,now:1_000_000_100)
    counter.record(packets:100,now:1_000_000_101)
    let counts=counter.stop()
    #expect(counts.callbacks==2 && counts.packets==5)
}

@Test func midiObservationRetirementCannotBeRearmedOrReplayEarlierTime() {
    let counter=BoundedMIDIObservation()
    let started=counter.begin(now:100,seconds:10)
    #expect(started)
    counter.record(packets:7,now:99)
    counter.record(packets:1,now:101)
    let restarted=counter.begin(now:102,seconds:1)
    #expect(!restarted)
    let counts=counter.stop()
    #expect(counts.callbacks==0 && counts.packets==0)
    counter.record(packets:1,now:103)
    #expect(counter.stop()==counts)
}

@Test func midiObservationRejectsInvalidDurationAndOverflow() {
    let counter=BoundedMIDIObservation()
    let a=counter.begin(now:1,seconds:0)
    let b=counter.begin(now:1,seconds:11)
    let c=counter.begin(now:UInt64.max-1,seconds:1)
    let d=counter.begin(now:1,seconds:1)
    #expect(!a && !b && !c && !d)
    #expect(counter.stop().packets==0)
}
