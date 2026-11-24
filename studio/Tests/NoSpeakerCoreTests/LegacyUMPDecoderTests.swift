import Testing
@testable import NoSpeakerCore

private func midi1Words(_ words: [UInt32]) -> [UInt32] {
    var result: [UInt32] = []
    words.withUnsafeBufferPointer { buffer in
        LegacyUMPDecoder.forEachMIDI1(in:buffer) { result.append($0) }
    }
    return result
}

@Test func legacyUMPDecoderSkipsMultiwordPayloadsThatResembleNotes() {
    let on: UInt32 = 0x20903c64, off: UInt32 = 0x20803c00
    #expect(midi1Words([0x40903c00,on,off]) == [off])
    #expect(midi1Words([0x50000000,on,off,on,off]) == [off])
    #expect(midi1Words([0xd0000000,on,off,on,on]) == [on])
    #expect(midi1Words([on,0x30000000,off,off]) == [on,off])
}
@Test func legacyUMPDecoderRejectsTruncatedAndInvalidChannelMessages() {
    let on: UInt32 = 0x20903c64
    #expect(midi1Words([on,0x50000000,on]) == [on])
    #expect(midi1Words([0x20f00000,0x20000000,on]) == [on])
    #expect(midi1Words([]).isEmpty)
}
@Test func legacyUMPDecoderWalksEveryMessageTypeAtDeclaredLength() {
    let lengths = [1,1,1,2,2,4,1,1,2,2,2,3,3,4,4,4]
    let on: UInt32 = 0x20903c64
    for type in 0..<16 where type != 2 {
        let message = [UInt32(type)<<28] + Array(repeating:on,count:lengths[type]-1)
        #expect(midi1Words(message+[on]) == [on])
    }
}
