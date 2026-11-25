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
