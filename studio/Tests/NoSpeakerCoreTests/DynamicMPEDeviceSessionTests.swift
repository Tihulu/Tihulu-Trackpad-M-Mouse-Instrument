import Foundation
import Testing
@testable import NoSpeakerCore

private func dynamicDeviceProfile() -> (PerformanceGroupProfile,[UUID:PerformanceGroupTuningPlan.Specification]) {
    var scale = CustomScale()
    scale.centOffsets = [2:20]
    let notes = (36...83).filter { scale.intervals.contains(($0-60+144)%12) }
    let group = PerformanceInstrumentGroup(name:"Wide",patch:.init(routes:notes.enumerated().map { i,note in
        .init(id:"note-\(i)",source:.gamepad1,signal:.padA,destination:.init(.note,number:note))
    }))
    return (.init(groups:[group]),[group.id:.init(scale:scale,root:60)])
}
private func dynamicFrame(_ held:Bool) throws -> GamepadFrame {
    var buttons = Array(repeating:0.0,count:12)
    buttons[0] = held ? 1 : 0
    return try #require(GamepadFrame(buttons:buttons,triggers:[0,0],sticks:[0,0,0,0]))
}

@Test func dynamicDeviceSessionExplicitSetupNeutralCapacityAndRelease() throws {
    let (profile,tuning) = dynamicDeviceProfile()
    #expect(throws:MIDIClipError.tuningCapacity) {
        try PerformanceGroupGamepadSession(profile:profile,tuning:tuning)
    }
    #expect(throws:PerformanceGroupGamepadSession.AdmissionError.unsupportedProfile) {
        try PerformanceGroupGamepadSession(profile:profile,dynamicMPE:true)
    }
    var session = try PerformanceGroupGamepadSession(profile:profile,tuning:tuning,dynamicMPE:true)
    #expect(throws:PerformanceGroupGamepadSession.AdmissionError.setupRequired) {
        try session.bind(.gamepad1,now:1)
    }
    let prepared = session.prepare { _ in true }
    #expect(prepared)
    let token = try session.bind(.gamepad1,now:1)
    let down = try dynamicFrame(true), up = try dynamicFrame(false)
    var sent:[PerformanceGroupCommand] = []
    let sink:(PerformanceGroupCommand)->Bool = { sent.append($0);return true }
    let held = session.receive(.gamepad1,token:token,frame:down,now:1.01,send:sink)
    #expect(held.status == .waitingForNeutral && sent.isEmpty)
    _ = session.receive(.gamepad1,token:token,frame:up,now:1.02,send:sink)
    let attack = session.receive(.gamepad1,token:token,frame:down,now:1.03,send:sink)
    #expect(attack.reports.first?.accepted == 15 && attack.reports.first?.capacityRefused == 13)
    #expect(attack.reports.first?.failedGroups.isEmpty == true)
    let addresses = Set(sent.map(\.command.destination))
    #expect(addresses.count == 15)
    sent.removeAll()
    _ = session.receive(.gamepad1,token:token,frame:down,now:1.04,send:sink)
    #expect(sent.isEmpty)
    let lift = session.receive(.gamepad1,token:token,frame:up,now:1.05,send:sink)
    #expect(lift.reports.first?.accepted == 15 && lift.reports.first?.capacityRefused == 0)
    #expect(Set(sent.map(\.command.destination)) == addresses && sent.allSatisfy { $0.command.value == 0 })
    #expect(session.pendingCleanup.isEmpty)
}

@Test func dynamicDeviceSessionTimeoutAndSetupFailureDoNotRearm() throws {
    let (profile,tuning) = dynamicDeviceProfile()
    var session = try PerformanceGroupGamepadSession(profile:profile,tuning:tuning,dynamicMPE:true)
    _ = session.prepare { _ in true }
    let token = try session.bind(.gamepad1,now:1)
    let down = try dynamicFrame(true), up = try dynamicFrame(false)
    var sent:[PerformanceGroupCommand] = []
    let sink:(PerformanceGroupCommand)->Bool = { sent.append($0);return true }
    _ = session.receive(.gamepad1,token:token,frame:up,now:1.01,send:sink)
    _ = session.receive(.gamepad1,token:token,frame:down,now:1.02,send:sink)
    let addresses = Set(sent.map(\.command.destination))
    sent.removeAll()
    _ = session.expire(now:1.4,send:sink)
    #expect(Set(sent.map(\.command.destination)) == addresses && sent.allSatisfy { $0.command.value == 0 })
    sent.removeAll()
    let held = session.receive(.gamepad1,token:token,frame:down,now:1.41,send:sink)
    #expect(held.status == .waitingForNeutral && sent.isEmpty)
    var failed = try PerformanceGroupGamepadSession(profile:profile,tuning:tuning,dynamicMPE:true)
    let prepared = failed.prepare { _ in false }
    #expect(!prepared && failed.retired && !failed.pendingCleanup.isEmpty)
    #expect(throws:PerformanceGroupGamepadSession.AdmissionError.retired) { try failed.bind(.gamepad1,now:1) }
}
