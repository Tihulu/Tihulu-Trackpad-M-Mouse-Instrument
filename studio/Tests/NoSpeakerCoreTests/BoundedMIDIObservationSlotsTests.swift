import Foundation
import Testing
@testable import NoSpeakerCore

@Test func boundedObserverSlotsNeverOverbookAndReleaseExactlyOnce() throws {
    var slots=BoundedMIDIObservationSlots()
    var tokens:[UUID]=[]
    for _ in 0..<BoundedMIDIObservationSlots.capacity {
        let token=slots.reserve()
        tokens.append(try #require(token))
    }
    let denied=slots.reserve()
    #expect(denied==nil && slots.count==4)
    let retired=slots.finish(tokens[1],portDisposalConfirmed:true)
    #expect(retired && slots.count==3)
    let repeated=slots.finish(tokens[1],portDisposalConfirmed:false)
    #expect(!repeated && !slots.recoveryRequired)
    let replacement=slots.reserve()
    #expect(replacement != nil && slots.count==4)
}

@Test func ambiguousObserverPortDisposalPreventsNewAdmissionWithoutDroppingOtherSlots() throws {
    var slots=BoundedMIDIObservationSlots()
    let first=slots.reserve(), second=slots.reserve()
    let a=try #require(first),b=try #require(second)
    let failed=slots.finish(a,portDisposalConfirmed:false)
    #expect(failed && slots.recoveryRequired && slots.count==1)
    let denied=slots.reserve()
    #expect(denied==nil)
    let other=slots.finish(b,portDisposalConfirmed:true)
    #expect(other && slots.count==0 && slots.recoveryRequired)
    let stillDenied=slots.reserve()
    #expect(stillDenied==nil)
}
