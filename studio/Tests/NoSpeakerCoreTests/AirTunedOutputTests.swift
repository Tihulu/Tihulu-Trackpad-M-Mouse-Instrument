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
    #expect(plan.setupCommands.filter{$0.destination.kind == .pitchBend}.count == plan.members.count)
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
