import Testing
@testable import NoSpeakerCore

@Test func customSurfaceMIDIMessageEncodesAllSupportedKinds() {
    #expect(CustomSurfaceMIDIMessage.bytes(for: .init(.init(.note, channel: 15, number: 127), value: 127)) == [0x9f, 127, 127])
    #expect(CustomSurfaceMIDIMessage.bytes(for: .init(.init(.note, channel: 2, number: 0), value: 0)) == [0x82, 0, 0])
    #expect(CustomSurfaceMIDIMessage.bytes(for: .init(.init(.sustain, channel: 2), value: 127)) == [0xb2, 64, 127])
    #expect(CustomSurfaceMIDIMessage.bytes(for: .init(.init(.sustain, channel: 2), value: 0)) == [0xb2, 64, 0])
    #expect(CustomSurfaceMIDIMessage.bytes(for: .init(.init(.controlChange, channel: 1, number: 11), value: 127)) == [0xb1, 11, 127])
    for (value, expected) in [(0,[UInt8(0xe3),0,0]), (8192,[0xe3,0,64]), (16383,[0xe3,127,127])] {
        #expect(CustomSurfaceMIDIMessage.bytes(for: .init(.init(.pitchBend, channel: 3), value: value)) == expected)
    }
}

@Test func customSurfaceMIDIMessageRejectsInvalidAndUnsafeCommands() {
    for command in [
        SensorCommand(.init(.note, channel: -1, number: 60), value: 100),
        .init(.init(.note, number: 128), value: 100),
        .init(.init(.note, number: 60), value: -1),
        .init(.init(.note, number: 60), value: 128),
        .init(.init(.sustain), value: 63),
        .init(.init(.sustain, number: 1), value: 127),
        .init(.init(.controlChange, number: 64), value: 127),
        .init(.init(.controlChange, number: 65), value: 127),
        .init(.init(.controlChange, number: 101), value: 1),
        .init(.init(.controlChange, number: 123), value: 0),
        .init(.init(.controlChange, number: 11), value: 128),
        .init(.init(.pitchBend), value: -1),
        .init(.init(.pitchBend), value: 16384)
    ] {
        #expect(CustomSurfaceMIDIMessage.bytes(for: command) == nil)
    }
}
