import Testing
@testable import NoSpeakerCore

@Test func legacyMIDI1ChannelMessageUsesCorrectStatusLength() {
    for channel in 0...15 {
        #expect(LegacyMIDI1Bytes.channelMessage(status:0xd0|channel,data1:99,data2:0) == [UInt8(0xd0|channel),99])
        #expect(LegacyMIDI1Bytes.channelMessage(status:0xc0|channel,data1:42,data2:0) == [UInt8(0xc0|channel),42])
        for status in [0x80,0x90,0xa0,0xb0,0xe0] {
            #expect(LegacyMIDI1Bytes.channelMessage(status:status|channel,data1:60,data2:127) ==
                [UInt8(status|channel),60,127])
        }
    }
}
@Test func legacyPressureDeduplicatesAndRetainsRetiredChannel() {
    var state = LegacyChannelPressure(), pool = LegacyMPEChannelPool()
    #expect(state.replace([1:60,2:90]) == [.init(1,60),.init(2,90)])
    #expect(state.replace([1:60,2:90]).isEmpty)
    _ = pool.retire(channel:1,sustained:true,fretless:false)
    let retained = state.values.filter { pool.reserved.contains($0.key) }
    #expect(state.replace(retained) == [.init(2,0)])
    #expect(state.replace([1:128]).isEmpty)
    #expect(state.values == [1:60])
    _ = pool.pedalChanged(sustained:[])
    #expect(state.release(1) == [.init(1,0)])
    #expect(state.replace([:]).isEmpty)
}
