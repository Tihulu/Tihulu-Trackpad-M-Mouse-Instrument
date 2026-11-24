#if os(macOS)
import CoreMIDI
import NoSpeakerCore

/// Borrow the event-list storage for the duration of the synchronous callback.
enum LegacyMIDIEventReader {
    static func forEachMIDI1(in eventList: UnsafePointer<MIDIEventList>, _ consume: (UInt32) -> Void) {
        // MIDIEventList contains variable-length packets inline. Traversing
        // a copied first packet with MIDIEventPacketNext reads unrelated memory.
        guard let packetOffset = MemoryLayout<MIDIEventList>.offset(of: \.packet),
              let wordOffset = MemoryLayout<MIDIEventPacket>.offset(of: \.words) else { return }
        let count = Int(eventList.pointee.numPackets)
        var packet = UnsafeRawPointer(eventList).advanced(by:packetOffset)
            .assumingMemoryBound(to:MIDIEventPacket.self)
        for index in 0..<count {
            let wordCount = Int(packet.pointee.wordCount)
            // CoreMIDI supplies the callback's valid packet storage. Do not
            // retain its pointer or copy the fixed-capacity C tuple.
            let words = UnsafeRawPointer(packet).advanced(by:wordOffset)
                .assumingMemoryBound(to:UInt32.self)
            LegacyUMPDecoder.forEachMIDI1(in:UnsafeBufferPointer(start:words,count:wordCount)) {
                consume($0)
            }
            if index+1 < count { packet = UnsafePointer(MIDIEventPacketNext(packet)) }
        }
    }
}
#endif
