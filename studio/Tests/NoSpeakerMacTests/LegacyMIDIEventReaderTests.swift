#if os(macOS)
import CoreMIDI
import Testing
@testable import NoSpeakerMac

@Test func nativeMIDIEventReaderTraversesDistinctTimestampPackets() throws {
    let storage = UnsafeMutableRawPointer.allocate(byteCount:4096,alignment:MemoryLayout<MIDIEventList>.alignment)
    defer { storage.deallocate() }
    let list = storage.bindMemory(to:MIDIEventList.self,capacity:1)
    var packet = MIDIEventListInit(list, ._1_0)
    let events: [(MIDITimeStamp,[UInt32])] = [
        (100,[0x20903c64,0x20904064]),
        (200,[0x20b0407f]),
        (300,[0x20803c00,0x20804000,0x20b04000])
    ]
    for (timestamp,words) in events {
        packet = words.withUnsafeBufferPointer { buffer in
            MIDIEventListAdd(list,4096,packet,timestamp,buffer.count,buffer.baseAddress!)
        }
    }
    #expect(list.pointee.numPackets == 3)
    var actual: [UInt32] = []
    LegacyMIDIEventReader.forEachMIDI1(in:UnsafePointer(list)) { actual.append($0) }
    #expect(actual == events.flatMap { $0.1 })
}
#endif
