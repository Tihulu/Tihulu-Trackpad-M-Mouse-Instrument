import Foundation
import Testing
@testable import NoSpeakerCore

private func hapticGroup(_ source:SensorSource,notes:[Int]) -> PerformanceInstrumentGroup {
    .init(name:source.rawValue,patch:.init(routes:notes.enumerated().map { i,note in
        .init(id:"note-\(i)",source:source,signal:GamepadFrame.buttons[i],destination:.init(.note,number:note))
    } + [
        .init(id:"sustain",source:source,signal:.padRT,destination:.init(.sustain)),
        .init(id:"bend",source:source,signal:.padLSX,destination:.init(.pitchBend))
    ]))
}
private func hapticCommand(_ group:PerformanceInstrumentGroup,_ target:SensorDestination,_ value:Int) -> PerformanceGroupCommand {
    .init(groupID:group.id,command:.init(target,value:value))
}

@Test func groupHapticProjectionKeepsEqualChannelNotesAndSustainIndependent() throws {
    let a = hapticGroup(.gamepad1,notes:[60]), b = hapticGroup(.gamepad2,notes:[60])
    let note = SensorDestination(.note,number:60), sustain = SensorDestination(.sustain)
    var preview = try PerformanceGroupHapticProjection(profile:.init(groups:[a,b]),selected:[a.id,b.id])
    preview.observe(hapticCommand(a,note,100),accepted:true)
    preview.observe(hapticCommand(b,note,100),accepted:true)
    let both = try #require(preview.frame())
    #expect(both.tones.count == 1)
    preview.observe(hapticCommand(a,sustain,127),accepted:true)
    preview.observe(hapticCommand(a,note,0),accepted:true)
    preview.observe(hapticCommand(b,note,0),accepted:true)
    #expect(preview.frame() != nil)
    preview.observe(hapticCommand(a,sustain,0),accepted:true)
    #expect(preview.frame() == nil)
}

@Test func groupHapticProjectionRetiresFailedGroupWithoutMutingSibling() throws {
    let a = hapticGroup(.gamepad1,notes:[60]), b = hapticGroup(.gamepad2,notes:[64])
    var preview = try PerformanceGroupHapticProjection(profile:.init(groups:[a,b]),selected:[a.id,b.id])
    let first = hapticCommand(a,.init(.note,number:60),100)
    let second = hapticCommand(b,.init(.note,number:64),100)
    preview.observe(first,accepted:true)
    preview.observe(second,accepted:true)
    #expect(preview.frame()?.tones.count == 2)
    preview.observe(hapticCommand(a,.init(.note,number:60),0),accepted:false)
    #expect(preview.activeGroups == [b.id])
    let survivor = preview.frame()
    preview.observe(first,accepted:true)
    #expect(preview.frame() == survivor && survivor?.tones.count == 1)
    preview.stop()
    preview.observe(second,accepted:true)
    #expect(preview.frame() == nil && preview.activeGroups.isEmpty)
}

@Test func groupHapticProjectionRefusesTunedUnknownOrUnselectedGroups() throws {
    let a = hapticGroup(.gamepad1,notes:[60]), b = hapticGroup(.gamepad2,notes:[64])
    let profile = PerformanceGroupProfile(groups:[a,b])
    #expect(throws:PerformanceGroupHapticProjection.AdmissionError.invalidSelection) {
        try PerformanceGroupHapticProjection(profile:profile,selected:[a.id],tuned:[a.id])
    }
    #expect(throws:PerformanceGroupHapticProjection.AdmissionError.invalidSelection) {
        try PerformanceGroupHapticProjection(profile:profile,selected:[UUID()])
    }
    var preview = try PerformanceGroupHapticProjection(profile:profile,selected:[a.id])
    preview.observe(hapticCommand(b,.init(.note,number:64),100),accepted:true)
    #expect(preview.frame() == nil)
    preview.observe(hapticCommand(a,.init(.note,number:61),100),accepted:true)
    #expect(preview.activeGroups.isEmpty)
}

@Test func groupHapticProjectionBoundsAndSharesSixToneBudget() throws {
    let a = hapticGroup(.gamepad1,notes:[48,50,52,53,55,57])
    let b = hapticGroup(.gamepad2,notes:[72,74,76,77,79,81])
    var preview = try PerformanceGroupHapticProjection(profile:.init(groups:[a,b]),selected:[a.id,b.id])
    for group in [a,b] {
        for route in group.patch.routes where route.destination.kind == .note {
            preview.observe(hapticCommand(group,route.destination,127),accepted:true)
        }
    }
    let frame = try #require(preview.frame())
    #expect(frame.tones.count == 6 && frame.level <= 1 && frame.durationMS == 18)
    #expect(frame.tones.filter { $0.frequencyHz < 500 }.count == 3)
    #expect(frame.tones.filter { $0.frequencyHz > 500 }.count == 3)
    #expect(abs(frame.tones.reduce(0.0) { $0+$1.amplitude }-1) < 0.0001)
}

@Test func groupHapticProjectionFollowsActualDeliveryFailureAndNeverRevivesOnCleanup() throws {
    let a = hapticGroup(.gamepad1,notes:[60]), b = hapticGroup(.gamepad2,notes:[64])
    let profile = PerformanceGroupProfile(groups:[a,b])
    var output = try PerformanceGroupDelivery(profile:profile)
    var haptic = try PerformanceGroupHapticProjection(profile:profile,selected:[a.id,b.id])
    let first = try output.connect(.gamepad1,now:1)
    let second = try output.connect(.gamepad2,now:1)
    let accept:(PerformanceGroupCommand)->Bool = { item in
        haptic.observe(item,accepted:true)
        return true
    }
    _ = output.frame(lease:first,sequence:1,now:1.01,values:[.padA:1],send:accept)
    _ = output.frame(lease:second,sequence:1,now:1.02,values:[.padA:1],send:accept)
    #expect(haptic.frame()?.tones.count == 2)
    let failed = output.frame(lease:first,sequence:2,now:1.03,values:[:],releasing:[.padA]) { item in
        haptic.observe(item,accepted:false)
        return false
    }
    #expect(failed.failedGroups == [a.id] && failed.pendingCleanup == [a.id])
    #expect(haptic.activeGroups == [b.id] && haptic.frame()?.tones.count == 1)
    let cleanup = output.retryCleanup(a.id,send:accept)
    #expect(cleanup.pendingCleanup.isEmpty && haptic.activeGroups == [b.id])
    _ = output.frame(lease:second,sequence:2,now:1.04,values:[:],releasing:[.padA],send:accept)
    #expect(haptic.frame() == nil)
    haptic.stop()
    _ = output.panic(send:accept)
    #expect(haptic.activeGroups.isEmpty && haptic.frame() == nil)
}
