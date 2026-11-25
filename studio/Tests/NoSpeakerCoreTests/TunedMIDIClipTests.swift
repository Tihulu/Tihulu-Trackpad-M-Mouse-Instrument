import Foundation
import Testing
@testable import NoSpeakerCore

@Test func tunedClipKeepsBendsFixedAndPreservesNoteTiming() throws {
    var scale = CustomScale()
    scale.centOffsets = [4:-30,7:25]
    let clip = MIDIClip(bpm:120,length:1920,notes:[
        .init(start:0,duration:480,channel:0,pitch:60,velocity:60),
        .init(start:0,duration:480,channel:0,pitch:64,velocity:70),
        .init(start:0,duration:480,channel:0,pitch:67,velocity:80),
        .init(start:480,duration:480,channel:0,pitch:76,velocity:90)])
    let tuned = try TunedMIDIClip(clip,scale:scale,root:60)
    #expect(tuned.members.map(\.bend) == [8192,6963,9216])
    #expect(tuned.clip.notes.map(\.channel) == [1,2,3,2])
    let data = tuned.encoded()
    #expect(data.range(of:Data([0xe2,51,54])) != nil)
    #expect(data.range(of:Data([0xe3,0,72])) != nil)
    #expect(data.range(of:Data([0xb0,100,6,0,0xb0,6,3])) != nil)
    let parsed = try MIDIFileParser.parse(data)
    #expect(parsed.notes.count == 4)
    #expect(parsed.notes.map(\.velocity) == [60,70,80,90])
    #expect(parsed.notes.last?.startSeconds == 0.25)
    #expect(data == tuned.encoded())
}
@Test func tunedClipRejectsCapacityAndMixedInstrumentRatherThanApproximate() throws {
    let scale = CustomScale()
    let notes = (0..<16).map { MIDIClip.Note(start:0,duration:240,channel:0,pitch:48+$0,velocity:90) }
    #expect(throws:MIDIClipError.tuningCapacity) {
        try TunedMIDIClip(.init(bpm:120,length:960,notes:notes),scale:scale,root:60)
    }
    var mixed = Array(notes.prefix(2))
    mixed[1].channel = 1
    #expect(throws:MIDIClipError.invalidClip) {
        try TunedMIDIClip(.init(bpm:120,length:960,notes:mixed),scale:scale,root:60)
    }
    var invalid = scale; invalid.centOffsets = [4:50]
    #expect(throws:MIDIClipError.invalidClip) {
        try TunedMIDIClip(.init(bpm:120,length:960,notes:Array(notes.prefix(2))),scale:invalid,root:60)
    }
}

@Test func tunedSequenceSetupUsesSameMembersAndRetainsSelectorDebt() throws {
    var scale = CustomScale(); scale.centOffsets = [4:-30]
    let tuned = try TunedMIDIClip(.init(bpm:120,length:960,notes:[
        .init(start:0,duration:240,channel:0,pitch:64,velocity:90)]),scale:scale,root:60)
    #expect(tuned.setupCommands.last == .init(.init(.pitchBend,channel:1),value:6963))
    let schedule = try MIDIClipSchedule(tuned.clip)
    #expect(schedule.events.map(\.command) == [.init(.init(.note,channel:1,number:64),value:90),.init(.init(.note,channel:1,number:64),value:0)])
    var selector = MIDISelectorCleanup()
    let ok = selector.configure(tuned.setupCommands,send:{ $0.destination.number != 6 })
    #expect(!ok && !selector.isEmpty)
    var cleanup:[SensorCommand] = []
    let released = selector.releaseAll(send:{ cleanup.append($0); return true })
    #expect(released && selector.isEmpty)
    #expect(cleanup == [.init(.init(.controlChange,channel:15,number:101),value:127),.init(.init(.controlChange,channel:15,number:100),value:127)])
}
