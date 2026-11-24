import Testing
@testable import NoSpeakerCore

@Test func legacyReceiveEpochRejectsStoppedAndReopenedSessionWork() throws {
    var epoch = LegacyReceiveEpoch()
    #expect(epoch.token == nil)
    epoch.begin()
    let first = try #require(epoch.token)
    #expect(epoch.accepts(first))
    epoch.end()
    #expect(!epoch.accepts(first))
    epoch.end()
    epoch.begin()
    let second = try #require(epoch.token)
    #expect(first != second)
    #expect(!epoch.accepts(first))
    #expect(epoch.accepts(second))
}

@Test func legacyReceiveEpochRejectsCapturedPacketAfterMultipleRestarts() throws {
    var epoch = LegacyReceiveEpoch()
    epoch.begin()
    let packet = try #require(epoch.token)
    for _ in 0..<100 {
        epoch.end()
        #expect(!epoch.accepts(packet))
        epoch.begin()
        #expect(!epoch.accepts(packet))
    }
    epoch.end()
    #expect(epoch.token == nil)
}
