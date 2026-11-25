import Foundation
import Testing
@testable import NoSpeakerCore

@Test func airTuningKeepsDistinctPitchesAndReleasesOnSameMember() throws {
    var scale = CustomScale(); scale.centOffsets = [4:-30,7:25]
    let patch = InstrumentPatch(routes:AirStrumPerformance.routes(bank:AirStrumPerformance.threeCourseBank))
    let plan = try AirTunedOutput(patch:patch,scale:scale,root:60)
    let pitch = SensorDestination(.note,number:52)
    let on = try #require(plan.translate(.init(pitch,value:83)))
    #expect(on.destination.channel > 0 && on.destination.number == 52 && on.value == 83)
    #expect(plan.translate(.init(pitch,value:0)) == .init(on.destination,value:0))
    #expect(plan.members.first(where:{$0.channel == on.destination.channel})?.bend == 6963)
    #expect(plan.translate(.init(.init(.note,number:127),value:80)) == nil)
    #expect(plan.translate(.init(.init(.pitchBend),value:8192)) == nil)
    #expect(plan.setupCommands.filter{$0.destination.kind == .pitchBend}.count == plan.members.count+1)
}
@Test func airTuningRejectsUnsupportedMixedPatchAndCapacity() throws {
    var scale = CustomScale(); scale.centOffsets = [4:-30]
    var patch = InstrumentPatch(routes:AirStrumPerformance.routes(bank:AirStrumPerformance.threeCourseBank))
    patch.routes.append(.init(id:"external",source:.trackpad,signal:.contact,destination:.init(.note,number:60)))
    #expect(throws:MIDIClipError.invalidClip) { try AirTunedOutput(patch:patch,scale:scale,root:60) }
    let bank = (0..<5).map { slot in (0..<4).map { 40+slot*4+$0 } }
    let dense = InstrumentPatch(routes:AirStrumPerformance.routes(bank:bank))
    #expect(throws:MIDIClipError.tuningCapacity) { try AirTunedOutput(patch:dense,scale:scale,root:60) }
    var invalid = scale; invalid.intervals = [0,Int.max]
    #expect(invalid.degreeCents.isEmpty)
}

@Test func airTunedStrumNativeAndDebugReleaseSameWireMembers() throws {
    var scale = CustomScale(); scale.centOffsets = [7:25]
    let patch = InstrumentPatch(routes:AirStrumPerformance.routes(bank:AirStrumPerformance.threeCourseBank))
    let plan = try AirTunedOutput(patch:patch,scale:scale,root:60)
    var live = PhysicalPatchRuntime()
    var debug = PatchSimulation()
    try live.configure(patch)
    try debug.start(patch,now:0)
    var wire:[SensorCommand] = []
    for (count,aperture,x,time) in [(0,0.8,0.0,0.0),(1,0.8,0.0,0.01),(1,0.8,0.0,0.15),(1,0.1,0.0,0.17),(1,0.1,1.0,0.22)] {
        let hand = AirHandSample.debugSample(x:x,y:0.5,aperture:aperture)
        let a = live.receiveDualHand(count:count,confidence:1,helper:hand,hostTime:time,now:time)
        let b = debug.receiveDualHand(count:count,confidence:1,helper:hand,time:time,now:time)
        #expect(a == b)
        wire += a.compactMap { plan.translate($0) }
    }
    #expect(wire.map(\.destination.number) == [48,55,60])
    #expect(Set(wire.map(\.destination.channel)).count == 3)
    #expect(wire.allSatisfy { $0.value > 0 })
    let off = live.expire(now:0.35)
    #expect(off == debug.expireDualHand(now:0.35))
    let translated = off.compactMap { plan.translate($0) }
    #expect(Set(translated.map(\.destination)) == Set(wire.map(\.destination)))
    #expect(translated.allSatisfy { $0.value == 0 })
}

@Test func tunedAirMasterEffectsAndRecordingPreserveMemberTuning() throws {
    var scale = CustomScale(); scale.centOffsets = [7:25]
    let notes = AirStrumPerformance.routes(bank:AirStrumPerformance.threeCourseBank,channel:3)
    let effects = AirDualHandPerformance.helperRoutes(channel:3)
    let pedal = try #require(AirHandsHelper.route(hand:.left,axis:.toggle,effect:.sustain,channel:3))
    let patch = InstrumentPatch(routes:notes+effects+[pedal])
    let plan = try AirTunedOutput(patch:patch,scale:scale,root:60)
    let note = SensorDestination(.note,channel:3,number:55)
    let bend = SensorDestination(.pitchBend,channel:3)
    let sustain = SensorDestination(.sustain,channel:3)
    let on = try #require(plan.translate(.init(note,value:87)))
    #expect(plan.translate(.init(bend,value:10000)) == .init(.init(.pitchBend),value:10000))
    #expect(plan.translate(.init(sustain,value:127)) == .init(.init(.sustain),value:127))
    #expect(plan.translate(.init(bend,value:16384)) == nil)
    var take = try #require(EnsembleTake(patch:patch,bpm:120,now:1,tuning:plan))
    let a = take.append(.init(note,value:87),now:1)
    let b = take.append(.init(sustain,value:127),now:1.01)
    let c = take.append(.init(bend,value:10000),now:1.02)
    #expect(a && b && c)
    take.finish(now:1.25)
    let file = try take.encoded()
    #expect(Array(file.prefix(14)) == [77,84,104,100,0,0,0,6,0,0,0,1,3,192])
    let pitch = UInt8(0xe0|on.destination.channel)
    let tuning = try #require(file.range(of:Data([pitch,0,72])))
    let noteOn = try #require(file.range(of:Data([UInt8(0x90|on.destination.channel),55,87])))
    #expect(tuning.lowerBound < noteOn.lowerBound)
    #expect(file.range(of:Data([0xb0,64,127])) != nil)
    #expect(file.range(of:Data([0xb0,64,0])) != nil)
    #expect(file.range(of:Data([0xe0,0,64])) != nil)
    let parsed = try MIDIFileParser.parse(file)
    #expect(parsed.notes.count == 1)
    #expect(parsed.notes.first?.channel == on.destination.channel)
    #expect(parsed.notes.first?.velocity == 87)
    #expect(EnsembleTake(patch:.starter,bpm:120,now:1,tuning:plan) == nil)
}
@Test func tunedAirRejectsUnknownMasterCCAndNonNeutralBendRelease() throws {
    var scale = CustomScale(); scale.centOffsets = [4:-30]
    var patch = InstrumentPatch(routes:AirStrumPerformance.routes(bank:AirStrumPerformance.threeCourseBank))
    patch.routes.append(.init(id:"unknown",source:.camera,signal:.x,destination:.init(.controlChange,number:12)))
    #expect(throws:MIDIClipError.invalidClip) { try AirTunedOutput(patch:patch,scale:scale,root:60) }
    patch.routes.removeLast()
    patch.routes.append(.init(id:"bend",source:.camera,signal:.x,destination:.init(.pitchBend),response:.init(release:0.9)))
    #expect(throws:MIDIClipError.invalidClip) { try AirTunedOutput(patch:patch,scale:scale,root:60) }
}
