import Foundation
import Testing
@testable import NoSpeakerCore

private func takePatch() -> InstrumentPatch {
    .init(routes:[
        .init(id:"a",source:.trackpad,signal:.contact,destination:.init(.note,channel:0,number:60)),
        .init(id:"b",source:.magicMouse,signal:.contact,destination:.init(.note,channel:1,number:64)),
        .init(id:"pedal",source:.trackpad,signal:.x,destination:.init(.sustain)),
        .init(id:"bend",source:.magicMouse,signal:.x,destination:.init(.pitchBend,channel:1)),
        .init(id:"filter",source:.magicMouse,signal:.y,destination:.init(.controlChange,channel:1,number:74),response:.init(release:0.5))])
}
@Test func ensembleTakeClosesEveryChannelAndPreservesControllerBytes() throws {
    var take = try #require(EnsembleTake(patch:takePatch(),bpm:120,now:10))
    let a = SensorDestination(.note,number:60), b = SensorDestination(.note,channel:1,number:64)
    let pedal = SensorDestination(.sustain), bend = SensorDestination(.pitchBend,channel:1)
    let filter = SensorDestination(.controlChange,channel:1,number:74)
    for c in [SensorCommand(a,value:100),.init(b,value:90),.init(pedal,value:127),.init(bend,value:9000),.init(filter,value:100)] {
        #expect(take.append(c,now:10.1))
    }
    take.finish(now:10.5)
    #expect(take.endTick == 960)
    #expect(take.events.suffix(5).map(\.command) == [.init(a,value:0),.init(pedal,value:0),.init(b,value:0),.init(bend,value:8192),.init(filter,value:64)])
    let data = try take.encoded()
    #expect(Array(data.prefix(14)) == [77,84,104,100,0,0,0,6,0,1,0,3,3,192])
    #expect(data.range(of:Data([0xB0,64,127])) != nil)
    #expect(data.range(of:Data([0xE1,40,70])) != nil)
    #expect(data.range(of:Data([0xB1,74,64])) != nil)
    let parsed = try MIDIFileParser.parse(data)
    #expect(parsed.notes.count == 2)
    #expect(Set(parsed.notes.map(\.channel)) == [0,1])
}
@Test func ensembleTakeBoundsAndRejectsInvalidCommandsWithoutReopening() throws {
    var take = try #require(EnsembleTake(patch:takePatch(),bpm:120,now:1))
    let a = SensorDestination(.note,number:60)
    #expect(take.append(.init(a,value:100),now:1))
    #expect(!take.append(.init(a,value:128),now:1.01))
    #expect(take.truncated)
    #expect(take.events.last?.command == .init(a,value:0))
    #expect(!take.append(.init(a,value:100),now:1.02))
    var long = try #require(EnsembleTake(patch:takePatch(),bpm:120,now:1))
    #expect(long.append(.init(a,value:100),now:1))
    long.checkTime(now:121)
    #expect(long.truncated && long.endTick == 230400)
    #expect(long.events.last?.command == .init(a,value:0))
    var full = try #require(EnsembleTake(patch:takePatch(),bpm:120,now:1))
    for _ in 0..<(EnsembleTake.maximumEvents-SensorRouter.maxMappings) {
        #expect(full.append(.init(a,value:100),now:1))
    }
    #expect(!full.append(.init(a,value:100),now:1))
    #expect(full.events.count <= EnsembleTake.maximumEvents)
    #expect(full.events.last?.command == .init(a,value:0))
}
