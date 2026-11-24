import Testing
@testable import NoSpeakerCore

@Test func legacyGateDebtRetainsFailedOnsetAndFailedRelease() {
    var debt = LegacyGateReleaseDebt()
    debt.record(.init(0x91,60,100),succeeded:false)
    debt.record(.init(0xb1,64,127),succeeded:true)
    debt.record(.init(0x81,60,0),succeeded:false)
    #expect(debt.pending == [.init(0xb1,64,0),.init(0x81,60,0)])
    debt.record(.init(0xb1,64,0),succeeded:true)
    debt.record(.init(0x91,60,0),succeeded:true)
    #expect(debt.isEmpty)
}
@Test func legacyGateDebtScopesCleanupAndDoesNotTrackOrdinaryCC() {
    var debt = LegacyGateReleaseDebt()
    for ch in [3,1] {
        debt.record(.init(0x90|ch,64,80),succeeded:true)
        debt.record(.init(0xb0|ch,64,127),succeeded:true)
    }
    debt.record(.init(0xb1,74,50),succeeded:false)
    debt.record(.init(0x81,64,0),succeeded:true)
    #expect(debt.pending == [.init(0xb1,64,0),.init(0xb3,64,0),.init(0x83,64,0)])
    #expect(!LegacyGateReleaseDebt.isGate(.init(0xb1,74,50)))
}
