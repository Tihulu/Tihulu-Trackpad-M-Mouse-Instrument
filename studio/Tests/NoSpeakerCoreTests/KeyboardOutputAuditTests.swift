import Testing
@testable import NoSpeakerCore

@Test func keyboardOutputAuditClassifiesActualMessagesAndFailure() {
    var audit = KeyboardOutputAudit()
    #expect(!audit.onlyPedal)
    audit.record(.init(0xb2,64,127),succeeded:true)
    audit.record(.init(0xb2,64,0),succeeded:true)
    #expect(audit.onlyPedal && audit.channels == [3])
    audit.record(.init(0xb2,7,127),succeeded:true)
    audit.record(.init(0xb2,11,127),succeeded:false)
    audit.record(.init(0x91,60,100),succeeded:true)
    audit.record(.init(0xe2,0,64),succeeded:true)
    audit.record(.init(0xd2,64,0),succeeded:true)
    audit.record(.init(0xb2,101,0),succeeded:true)
    #expect(!audit.onlyPedal && audit.attempts == 8)
    #expect(audit.notes == 1 && audit.volume == 1 && audit.expression == 1)
    #expect(audit.pitch == 1 && audit.pressure == 1 && audit.other == 1 && audit.failed == 1)
    #expect(audit.channels == [2,3])
}
@Test func keyboardOutputAuditHasFixedCapacity() {
    var audit = KeyboardOutputAudit()
    for _ in 0...KeyboardOutputAudit.limit { audit.record(.init(0xb0,64,0),succeeded:true) }
    #expect(audit.saturated && audit.attempts == KeyboardOutputAudit.limit)
    #expect(audit.pedal == KeyboardOutputAudit.limit)
}
