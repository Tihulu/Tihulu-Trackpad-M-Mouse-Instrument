/// Walk complete Universal MIDI Packet messages, including unsupported types.
/// Never interpret a continuation word as a fresh MIDI 1.0 channel message.
public enum LegacyUMPDecoder {
    // UMP message type determines packet size, including reserved types.
    private static let wordCounts = [1,1,1,2,2,4,1,1,2,2,2,3,3,4,4,4]

    public static func forEachMIDI1(in words: UnsafeBufferPointer<UInt32>,
                                   _ consume: (UInt32) -> Void) {
        var index = 0
        while index < words.count {
            let word = words[index]
            let type = Int(word >> 28)
            let length = wordCounts[type]
            guard length <= words.count-index else { return }
            if type == 2 {
                let status = Int((word >> 16) & 0xf0)
                if (0x80...0xe0).contains(status) { consume(word) }
            }
            index += length
        }
    }
}
