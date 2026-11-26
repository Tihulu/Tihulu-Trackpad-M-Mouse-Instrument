import Foundation
import Testing
@testable import NoSpeakerCore

private func gamepadSnapshot(_ pressed: Bool = false, trigger: Double = 0,
                             stick: Double = 0) throws -> GamepadFrame {
    var buttons = Array(repeating:0.0,count:12)
    buttons[0] = pressed ? 1 : 0
    return try #require(GamepadFrame(buttons:buttons,triggers:[0,trigger],sticks:[stick,0,0,0]))
}
private func gamepadGroup(_ source: SensorSource) -> PerformanceInstrumentGroup {
    .init(name:source.rawValue,patch:.init(routes:GamepadFrame.Role.lead.routes(source:source,channel:0)))
}

@Test func groupGamepadRequiresNeutralAndRejectsStalePhysicalBinding() throws {
    let group = gamepadGroup(.gamepad1)
    var engine = try PerformanceGroupGamepadSession(profile:.init(groups:[group]))
    let token = try engine.bind(.gamepad1,now:0)
    let held = try gamepadSnapshot(true)
    let neutral = try gamepadSnapshot()
    var output: [PerformanceGroupCommand] = []
    let sink: (PerformanceGroupCommand) -> Bool = { output.append($0); return true }
    let initial = engine.receive(.gamepad1,token:token,frame:held,now:0,send:sink)
    #expect(initial.status == .waitingForNeutral && output.isEmpty)
    let ready = engine.receive(.gamepad1,token:token,frame:neutral,now:0.01,send:sink)
    #expect(ready.status == .ready && output.isEmpty)
    _ = engine.receive(.gamepad1,token:token,frame:held,now:0.02,send:sink)
    #expect(output.map { $0.command.value } == [100])
    _ = engine.unbind(.gamepad1,token:token,send:sink)
    #expect(output.map { $0.command.value } == [100,0])
    let replacement = try engine.bind(.gamepad1,now:0.03)
    #expect(replacement != token)
    let ignored = engine.receive(.gamepad1,token:token,frame:neutral,now:0.04,send:sink)
    #expect(ignored.status == .ignored)
    let blocked = engine.receive(.gamepad1,token:replacement,frame:held,now:0.05,send:sink)
    #expect(blocked.status == .waitingForNeutral && output.count == 2)
}

@Test func groupGamepadFourSlotsKeepOtherNotesAndPedalsDuringTimeout() throws {
    let sources = GamepadFrame.orderedSources
    let groups = sources.map(gamepadGroup)
    var engine = try PerformanceGroupGamepadSession(profile:.init(groups:groups))
    let neutral = try gamepadSnapshot()
    let held = try gamepadSnapshot(true,trigger:1)
    var tokens: [SensorSource:UUID] = [:]
    var output: [PerformanceGroupCommand] = []
    let sink: (PerformanceGroupCommand) -> Bool = { output.append($0); return true }
    for source in sources {
        let token = try engine.bind(source,now:0)
        tokens[source] = token
        _ = engine.receive(source,token:token,frame:neutral,now:0,send:sink)
        _ = engine.receive(source,token:token,frame:held,now:0,send:sink)
    }
    #expect(engine.activeSessions == 4)
    #expect(output.filter { $0.command.value == 100 }.count == 4)
    output.removeAll()
    for source in sources.dropFirst() {
        _ = engine.receive(source,token:try #require(tokens[source]),frame:held,now:0.2,send:sink)
    }
    #expect(output.isEmpty)
    _ = engine.expire(now:0.36,send:sink)
    #expect(engine.activeSessions == 3)
    #expect(output.count == 2 && output.allSatisfy { $0.groupID == groups[0].id && $0.command.value == 0 })
    output.removeAll()
    let first = try #require(tokens[sources[0]])
    let waiting = engine.receive(sources[0],token:first,frame:held,now:0.37,send:sink)
    #expect(waiting.status == .waitingForNeutral && output.isEmpty)
    _ = engine.receive(sources[0],token:first,frame:neutral,now:0.38,send:sink)
    _ = engine.receive(sources[0],token:first,frame:held,now:0.39,send:sink)
    #expect(output.count == 2 && engine.activeSessions == 4)
}

@Test func groupGamepadBatchExpiryNeverRestoresAlsoExpiredCCOwner() throws {
    let target = SensorDestination(.controlChange,number:74)
    let group = PerformanceInstrumentGroup(name:"Shared CC",patch:.init(routes:[
        .init(id:"one",source:.gamepad1,signal:.padLT,destination:target,priority:10),
        .init(id:"two",source:.gamepad2,signal:.padLT,destination:target,priority:0)
    ]))
    var engine = try PerformanceGroupGamepadSession(profile:.init(groups:[group]))
    let a = try engine.bind(.gamepad1,now:0)
    let b = try engine.bind(.gamepad2,now:0)
    let neutral = try gamepadSnapshot()
    var output: [PerformanceGroupCommand] = []
    let sink: (PerformanceGroupCommand) -> Bool = { output.append($0); return true }
    _ = engine.receive(.gamepad1,token:a,frame:neutral,now:0,send:sink)
    _ = engine.receive(.gamepad2,token:b,frame:neutral,now:0,send:sink)
    for (source,token,value) in [(SensorSource.gamepad1,a,0.8),(SensorSource.gamepad2,b,0.3)] {
        let frame = try #require(GamepadFrame(buttons:Array(repeating:0,count:12),triggers:[value,0],sticks:[0,0,0,0]))
        _ = engine.receive(source,token:token,frame:frame,now:0.01,send:sink)
    }
    #expect(engine.activeSessions == 2)
    output.removeAll()
    _ = engine.expire(now:0.4,send:sink)
    #expect(output == [.init(groupID:group.id,command:.init(target,value:0))])
    #expect(engine.activeSessions == 0)
}

@Test func groupGamepadScopeFailureDebtAndTerminalPanic() throws {
    let a = gamepadGroup(.gamepad1)
    let b = gamepadGroup(.gamepad2)
    var engine = try PerformanceGroupGamepadSession(profile:.init(groups:[a,b]))
    let x = try engine.bind(.gamepad1,now:0)
    let y = try engine.bind(.gamepad2,now:0)
    let neutral = try gamepadSnapshot()
    let held = try gamepadSnapshot(true)
    _ = engine.receive(.gamepad1,token:x,frame:neutral,now:0,send:{ _ in true })
    _ = engine.receive(.gamepad2,token:y,frame:neutral,now:0,send:{ _ in true })
    _ = engine.receive(.gamepad2,token:y,frame:held,now:0.01,send:{ _ in true })
    let failure = engine.receive(.gamepad1,token:x,frame:held,now:0.01,send:{ _ in false })
    #expect(failure.status == .lost && engine.sourceStates[.gamepad1] == .waitingForNeutral)
    #expect(failure.reports.last?.failedGroups == [a.id])
    #expect(engine.pendingCleanup == [a.id] && engine.activeSessions == 1)
    var output: [PerformanceGroupCommand] = []
    let recovered = engine.retryCleanup(a.id,send:{ output.append($0); return true })
    #expect(recovered.pendingCleanup.isEmpty && output.allSatisfy { $0.groupID == a.id })
    output.removeAll()
    _ = engine.panic(send:{ output.append($0); return true })
    #expect(output.count == 1 && output[0].groupID == b.id && output[0].command.value == 0)
    #expect(engine.retired && engine.boundSources.isEmpty)
    #expect(throws: PerformanceGroupGamepadSession.AdmissionError.retired) {
        try engine.bind(.gamepad2,now:1)
    }
}

@Test func groupGamepadRejectsMixedProfileAndClockRegressionFailsClosed() throws {
    let mixed = PerformanceGroupProfile(groups:[gamepadGroup(.gamepad1),.init(name:"Touch",patch:.starter)])
    #expect(throws: PerformanceGroupGamepadSession.AdmissionError.unsupportedProfile) {
        try PerformanceGroupGamepadSession(profile:mixed)
    }
    var engine = try PerformanceGroupGamepadSession(profile:.init(groups:[gamepadGroup(.gamepad1)]))
    let token = try engine.bind(.gamepad1,now:1)
    let neutral = try gamepadSnapshot()
    let held = try gamepadSnapshot(true)
    _ = engine.receive(.gamepad1,token:token,frame:neutral,now:1,send:{ _ in true })
    _ = engine.receive(.gamepad1,token:token,frame:held,now:1.01,send:{ _ in true })
    var output: [PerformanceGroupCommand] = []
    let backwards = engine.receive(.gamepad1,token:token,frame:held,now:0.99,send:{ output.append($0); return true })
    #expect(backwards.status == .lost && output.map { $0.command.value } == [0])
    let waiting = engine.receive(.gamepad1,token:token,frame:held,now:1.02,send:{ output.append($0); return true })
    #expect(waiting.status == .waitingForNeutral && output.count == 1)
}


@Test func groupGamepadToggleSurvivesOrdinaryLiftButNotDeviceLoss() throws {
    let target = SensorDestination(.sustain)
    let group = PerformanceInstrumentGroup(name:"Pedal",patch:.init(routes:[
        .init(id:"toggle",source:.gamepad1,signal:.padRT,destination:target,pedalMode:.toggle)
    ]))
    var engine = try PerformanceGroupGamepadSession(profile:.init(groups:[group]))
    let token = try engine.bind(.gamepad1,now:0)
    let neutral = try gamepadSnapshot()
    let down = try gamepadSnapshot(trigger:1)
    var values: [Int] = []
    let sink: (PerformanceGroupCommand) -> Bool = { values.append($0.command.value); return true }
    _ = engine.receive(.gamepad1,token:token,frame:neutral,now:0,send:sink)
    _ = engine.receive(.gamepad1,token:token,frame:down,now:0.01,send:sink)
    _ = engine.receive(.gamepad1,token:token,frame:neutral,now:0.02,send:sink)
    #expect(values == [127])
    _ = engine.receive(.gamepad1,token:token,frame:nil,now:0.03,send:sink)
    #expect(values == [127,0])
    _ = engine.receive(.gamepad1,token:token,frame:down,now:0.04,send:sink)
    #expect(values == [127,0])
}

@Test func groupGamepadRapidEdgesAreNotCoalescedAcrossFourControllers() throws {
    let sources = GamepadFrame.orderedSources
    let groups = sources.map(gamepadGroup)
    var engine = try PerformanceGroupGamepadSession(profile:.init(groups:groups))
    let neutral = try gamepadSnapshot()
    let down = try gamepadSnapshot(true)
    var tokens: [SensorSource:UUID] = [:]
    var counts: [UUID:Int] = [:]
    var bad = 0
    let sink: (PerformanceGroupCommand) -> Bool = { event in
        let count = counts[event.groupID,default:0]
        if event.command.destination.kind != .note || event.command.value != (count % 2 == 0 ? 100 : 0) { bad += 1 }
        counts[event.groupID] = count+1
        return true
    }
    for source in sources {
        let token = try engine.bind(source,now:0)
        tokens[source] = token
        _ = engine.receive(source,token:token,frame:neutral,now:0,send:sink)
    }
    for step in 1...1000 {
        let now = Double(step)*0.004
        for source in sources {
            let token = try #require(tokens[source])
            let frame = step % 2 == 1 ? down : neutral
            _ = engine.receive(source,token:token,frame:frame,now:now,send:sink)
            _ = engine.receive(source,token:token,frame:frame,now:now,send:sink)
        }
    }
    #expect(bad == 0)
    #expect(groups.allSatisfy { counts[$0.id] == 1000 })
    let final = engine.panic(send:sink)
    #expect(final.accepted == 0 && final.pendingCleanup.isEmpty)
}


@Test func groupManualStopAndRetryDrainOtherExpiredNotesBeforeReturning() throws {
    for retry in [false,true] {
        let a = gamepadGroup(.gamepad1)
        let b = gamepadGroup(.gamepad2)
        let c = gamepadGroup(.gamepad3)
        var engine = try PerformanceGroupGamepadSession(profile:.init(groups:[a,b,c]))
        let x = try engine.bind(.gamepad1,now:0)
        let y = try engine.bind(.gamepad2,now:0)
        let z = try engine.bind(.gamepad3,now:0)
        let neutral = try gamepadSnapshot()
        let held = try gamepadSnapshot(true)
        let sources:[(SensorSource,UUID)] = [(.gamepad1,x),(.gamepad2,y),(.gamepad3,z)]
        for (source,token) in sources {
            _ = engine.receive(source,token:token,frame:neutral,now:0,send:{ _ in true })
        }
        for (source,token) in sources {
            _ = engine.receive(source,token:token,frame:held,now:0.01,send:{ _ in true })
        }
        #expect(engine.activeSessions == 3)
        if retry {
            let failed = engine.stopGroup(a.id,send:{ _ in false })
            #expect(failed.pendingCleanup == [a.id])
        }
        _ = engine.receive(.gamepad3,token:z,frame:held,now:0.25,send:{ _ in true })
        var now = 0.25
        var sent:[PerformanceGroupCommand] = []
        let sink:(PerformanceGroupCommand)->Bool = { command in
            sent.append(command)
            if command.groupID == a.id { now = 0.37 }
            return true
        }
        let result = retry
            ? engine.retryCleanup(a.id,refreshNow:{now},send:sink)
            : engine.stopGroup(a.id,refreshNow:{now},send:sink)
        #expect(result.pendingCleanup.isEmpty && result.failedGroups.isEmpty)
        #expect(sent.count == 2 && sent.map(\.groupID) == [a.id,b.id])
        #expect(sent.allSatisfy { $0.command.value == 0 })
        #expect(engine.sourceStates[.gamepad2] == .waitingForNeutral)
        #expect(engine.sourceStates[.gamepad3] == .leased && engine.activeSessions == 1)
    }
}


@Test func groupManualDrainPreservesNewFailureAndFinalCleanupDebt() throws {
    let a = gamepadGroup(.gamepad1)
    let b = gamepadGroup(.gamepad2)
    var engine = try PerformanceGroupGamepadSession(profile:.init(groups:[a,b]))
    let x = try engine.bind(.gamepad1,now:0)
    let y = try engine.bind(.gamepad2,now:0)
    let neutral = try gamepadSnapshot()
    let held = try gamepadSnapshot(true)
    let sources:[(SensorSource,UUID)] = [(.gamepad1,x),(.gamepad2,y)]
    for (source,token) in sources {
        _ = engine.receive(source,token:token,frame:neutral,now:0,send:{_ in true})
    }
    for (source,token) in sources {
        _ = engine.receive(source,token:token,frame:held,now:0.01,send:{_ in true})
    }
    #expect(engine.activeSessions == 2)
    let first = engine.stopGroup(a.id,send:{_ in false})
    #expect(first.pendingCleanup == [a.id])
    var now = 0.25
    let report = engine.retryCleanup(a.id,refreshNow:{now}) { command in
        if command.groupID == a.id { now = 0.37; return true }
        return false
    }
    #expect(report.failedGroups == [b.id] && report.pendingCleanup == [b.id])
    #expect(engine.pendingCleanup == [b.id] && engine.activeSessions == 0)
}
