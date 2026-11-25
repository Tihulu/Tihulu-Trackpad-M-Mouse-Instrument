import Foundation
import Testing
@testable import NoSpeakerCore

private func groupTuning(_ cents:Int) -> PerformanceGroupTuningPlan.Specification {
    var scale = CustomScale()
    scale.centOffsets = [2:cents]
    return .init(scale:scale,root:60)
}

private func tunedGroup(_ source:SensorSource,id:UUID = UUID(),channel:Int = 3) -> PerformanceInstrumentGroup {
    .init(id:id,name:source.rawValue,patch:.init(routes:[
        .init(id:"note",source:source,signal:.padA,destination:.init(.note,channel:channel,number:62)),
        .init(id:"other",source:source,signal:.padB,destination:.init(.note,channel:channel,number:64)),
        .init(id:"bend",source:source,signal:.padLSX,destination:.init(.pitchBend,channel:channel)),
        .init(id:"pedal",source:source,signal:.padRT,destination:.init(.sustain,channel:channel))
    ]))
}

@Test func groupTuningKeepsIndependentPortBendsAndStableNoteOffMembers() throws {
    let a = tunedGroup(.gamepad1)
    let b = tunedGroup(.gamepad2)
    let standard = tunedGroup(.gamepad3)
    let profile = PerformanceGroupProfile(groups:[a,b,standard])
    let plan = try PerformanceGroupTuningPlan(profile:profile,tuning:[a.id:groupTuning(-20),b.id:groupTuning(20)])
    let za = try #require(plan.zones[a.id])
    let zb = try #require(plan.zones[b.id])
    #expect(za.members.map(\.channel) == [1,2])
    #expect(zb.members.map(\.channel) == [1,2])
    #expect(za.members[0].bend < 8192 && zb.members[0].bend > 8192)
    let note = SensorDestination(.note,channel:3,number:62)
    let on = try #require(plan.translate(.init(groupID:a.id,command:.init(note,value:100))))
    let off = try #require(plan.translate(.init(groupID:a.id,command:.init(note,value:0))))
    #expect(on.command.destination == off.command.destination)
    #expect(on.command.destination.channel == 1 && off.command.value == 0)
    let normal = PerformanceGroupCommand(groupID:standard.id,command:.init(note,value:100))
    #expect(plan.translate(normal) == normal)
    #expect(plan.translate(.init(groupID:a.id,command:.init(.init(.pitchBend,channel:3),value:10000))) ==
        .init(groupID:a.id,command:.init(.init(.pitchBend),value:10000)))
    #expect(plan.translate(.init(groupID:b.id,command:.init(.init(.sustain,channel:3),value:127))) ==
        .init(groupID:b.id,command:.init(.init(.sustain),value:127)))
    #expect(plan.translate(.init(groupID:a.id,command:.init(.init(.note,channel:3,number:63),value:80))) == nil)
    #expect(plan.translate(.init(groupID:UUID(),command:.init(note,value:100))) == nil)
}

@Test func groupTuningRejectsOffScaleCapacityMixedChannelAndUnsafeEffects() throws {
    var group = tunedGroup(.gamepad1)
    let spec = groupTuning(-20)
    group.patch.routes[0].destination.number = 61
    #expect(throws:MIDIClipError.invalidNote) {
        try PerformanceGroupTuningPlan(profile:.init(groups:[group]),tuning:[group.id:spec])
    }
    group = tunedGroup(.gamepad1)
    group.patch.routes[1].destination.channel = 2
    #expect(throws:MIDIClipError.invalidClip) {
        try PerformanceGroupTuningPlan(profile:.init(groups:[group]),tuning:[group.id:spec])
    }
    group = tunedGroup(.gamepad1)
    group.patch.routes.append(.init(id:"setup",source:.gamepad1,signal:.padLT,destination:.init(.controlChange,channel:3,number:6)))
    #expect(throws:MIDIClipError.invalidClip) {
        try PerformanceGroupTuningPlan(profile:.init(groups:[group]),tuning:[group.id:spec])
    }
    group = tunedGroup(.gamepad1)
    group.patch.routes = (0..<16).map { index in
        .init(id:"n"+String(index),source:.gamepad1,signal:.padA,
              destination:.init(.note,channel:3,number:36+(index/7)*12+[0,2,4,5,7,9,11][index%7]))
    }
    #expect(throws:MIDIClipError.tuningCapacity) {
        try PerformanceGroupTuningPlan(profile:.init(groups:[group]),tuning:[group.id:spec])
    }
}

@Test func groupTunedDeliverySetupBeforeNotesAndScopedPanicPreserveMemberBends() throws {
    let a = tunedGroup(.gamepad1)
    let b = tunedGroup(.gamepad2)
    var session = try PerformanceGroupTunedDelivery(profile:.init(groups:[a,b]),
        tuning:[a.id:groupTuning(-20),b.id:groupTuning(20)])
    #expect(throws:PerformanceGroupTunedDelivery.AdmissionError.notReady) {
        try session.connect(.gamepad1,now:0)
    }
    var wire: [PerformanceGroupCommand] = []
    let sink: (PerformanceGroupCommand)->Bool = { wire.append($0); return true }
    let prepared = session.prepare(send:sink)
    #expect(prepared && session.state == .ready && session.pendingCleanup.isEmpty)
    #expect(wire.allSatisfy { $0.command.destination.kind != .note })
    #expect(Set(wire.map(\.groupID)) == [a.id,b.id])
    wire.removeAll()
    let x = try session.connect(.gamepad1,now:0)
    let y = try session.connect(.gamepad2,now:0)
    _ = session.frame(lease:x,sequence:1,now:0.01,values:[.padA:1,.padRT:1],send:sink)
    _ = session.frame(lease:y,sequence:1,now:0.01,values:[.padA:1],send:sink)
    #expect(wire.filter { $0.command.destination.kind == .note }.map { $0.command.destination.channel } == [1,1])
    wire.removeAll()
    _ = session.stopGroup(a.id,send:sink)
    #expect(wire.count == 2 && wire.allSatisfy { $0.groupID == a.id && $0.command.value == 0 })
    wire.removeAll()
    _ = session.panic(send:sink)
    #expect(wire.count == 1 && wire[0].groupID == b.id && wire[0].command.destination.channel == 1 && wire[0].command.value == 0)
    #expect(session.pendingCleanup.isEmpty && session.state == .retired)
}

@Test func groupTunedSetupFailureRetainsOriginalPortSelectorDebtAndBlocksAllNotes() throws {
    let a = tunedGroup(.gamepad1,id:try #require(UUID(uuidString:"00000000-0000-0000-0000-000000000001")))
    let b = tunedGroup(.gamepad2,id:try #require(UUID(uuidString:"00000000-0000-0000-0000-000000000002")))
    var session = try PerformanceGroupTunedDelivery(profile:.init(groups:[a,b]),
        tuning:[a.id:groupTuning(-20),b.id:groupTuning(20)])
    var wire: [PerformanceGroupCommand] = []
    let prepared = session.prepare { item in
        wire.append(item)
        return item.groupID != b.id
    }
    #expect(!prepared && session.state == .retired && session.pendingCleanup == [b.id])
    #expect(throws:PerformanceGroupTunedDelivery.AdmissionError.notReady) {
        try session.connect(.gamepad1,now:0)
    }
    wire.removeAll()
    let wrong = session.retryCleanup(a.id) { wire.append($0); return true }
    #expect(wrong && wire.isEmpty && session.pendingCleanup == [b.id])
    let recovered = session.retryCleanup(b.id) { wire.append($0); return true }
    #expect(recovered && session.pendingCleanup.isEmpty)
    #expect(wire.count == 2 && wire.allSatisfy { $0.groupID == b.id && $0.command.value == 127 })
    let again = session.prepare { _ in true }
    #expect(!again && session.state == .retired)
}

@Test func groupTunedFailedNoteReleaseRetriesSameMemberOnly() throws {
    let a = tunedGroup(.gamepad1)
    var session = try PerformanceGroupTunedDelivery(profile:.init(groups:[a]),tuning:[a.id:groupTuning(-20)])
    let ready = session.prepare { _ in true }
    #expect(ready)
    let lease = try session.connect(.gamepad1,now:0)
    _ = session.frame(lease:lease,sequence:1,now:0.01,values:[.padA:1],send:{ _ in true })
    _ = session.disconnect(lease,send:{ _ in false })
    #expect(session.pendingCleanup == [a.id])
    var wire: [PerformanceGroupCommand] = []
    let clean = session.retryCleanup(a.id) { wire.append($0); return true }
    #expect(clean && session.pendingCleanup.isEmpty)
    #expect(wire == [.init(groupID:a.id,command:.init(.init(.note,channel:1,number:62),value:0))])
}


private func groupTunedSnapshot(_ down:Bool = false) throws -> GamepadFrame {
    var buttons = Array(repeating:0.0,count:12)
    buttons[0] = down ? 1 : 0
    return try #require(GamepadFrame(buttons:buttons,triggers:[0,down ? 1 : 0],sticks:[0,0,0,0]))
}

@Test func groupTunedLocalSessionPreservesExistingWatchdogAndStandardSibling() throws {
    let a = tunedGroup(.gamepad1)
    let b = tunedGroup(.gamepad2)
    var engine = try PerformanceGroupGamepadSession(profile:.init(groups:[a,b]),
        tuning:[a.id:groupTuning(-20)])
    #expect(throws:PerformanceGroupGamepadSession.AdmissionError.setupRequired) {
        try engine.bind(.gamepad1,now:0)
    }
    var wire: [PerformanceGroupCommand] = []
    let sink: (PerformanceGroupCommand)->Bool = { wire.append($0); return true }
    let prepared = engine.prepare(send:sink)
    #expect(prepared && wire.allSatisfy { $0.groupID == a.id && $0.command.destination.kind != .note })
    wire.removeAll()
    let x = try engine.bind(.gamepad1,now:0)
    let y = try engine.bind(.gamepad2,now:0)
    let down = try groupTunedSnapshot(true)
    let up = try groupTunedSnapshot()
    let held = engine.receive(.gamepad1,token:x,frame:down,now:0,send:sink)
    #expect(held.status == .waitingForNeutral && wire.isEmpty)
    _ = engine.receive(.gamepad1,token:x,frame:up,now:0.01,send:sink)
    _ = engine.receive(.gamepad2,token:y,frame:up,now:0.01,send:sink)
    _ = engine.receive(.gamepad1,token:x,frame:down,now:0.02,send:sink)
    _ = engine.receive(.gamepad2,token:y,frame:down,now:0.02,send:sink)
    #expect(wire.filter { $0.command.destination.kind == .note }.map { $0.command.destination.channel } == [1,3])
    #expect(wire.filter { $0.command.destination.kind == .sustain }.map { $0.command.destination.channel } == [0,3])
    wire.removeAll()
    _ = engine.receive(.gamepad2,token:y,frame:down,now:0.2,send:sink)
    _ = engine.expire(now:0.38,send:sink)
    #expect(wire.count == 2 && wire.allSatisfy { $0.groupID == a.id && $0.command.value == 0 })
    #expect(wire.first(where:{ $0.command.destination.kind == .note })?.command.destination.channel == 1)
    #expect(engine.activeSessions == 1)
    wire.removeAll()
    let blocked = engine.receive(.gamepad1,token:x,frame:down,now:0.39,send:sink)
    #expect(blocked.status == .waitingForNeutral && wire.isEmpty)
    _ = engine.panic(send:sink)
    #expect(wire.count == 2 && wire.allSatisfy { $0.groupID == b.id && $0.command.value == 0 })
}

@Test func groupTunedLocalSetupFailureRemainsTerminalWithSelectorDebt() throws {
    let group = tunedGroup(.gamepad1)
    var engine = try PerformanceGroupGamepadSession(profile:.init(groups:[group]),
        tuning:[group.id:groupTuning(-20)])
    let ready = engine.prepare { _ in false }
    #expect(!ready && engine.retired && engine.pendingCleanup == [group.id])
    #expect(throws:PerformanceGroupGamepadSession.AdmissionError.retired) {
        try engine.bind(.gamepad1,now:0)
    }
    let stopped = engine.panic { _ in false }
    #expect(stopped.pendingCleanup == [group.id])
    var wire: [PerformanceGroupCommand] = []
    let recovered = engine.retryCleanup(group.id) { wire.append($0); return true }
    #expect(recovered.pendingCleanup.isEmpty && engine.pendingCleanup.isEmpty)
    #expect(wire.count == 2 && wire.allSatisfy { $0.groupID == group.id && $0.command.value == 127 })
    let retry = engine.prepare { _ in true }
    #expect(!retry && engine.retired)
}


@Test func groupTuningArchiveKeepsIdentityAcrossRenameAndReorderButRejectsChangedMappings() throws {
    let a = tunedGroup(.gamepad1)
    let b = tunedGroup(.gamepad2)
    let profile = PerformanceGroupProfile(groups:[a,b])
    let config = try PerformanceGroupTuningConfiguration(profile:profile,tuning:[a.id:groupTuning(-20)])
    let bytes = try config.archive()
    let loaded = try PerformanceGroupTuningConfiguration.read(bytes,matching:profile)
    #expect(loaded == config)
    var reordered = profile
    reordered.groups[0].name = "Renamed instrument"
    reordered.groups.swapAt(0,1)
    let plan = try loaded.plan(matching:reordered)
    #expect(Set(plan.zones.keys) == [a.id])
    reordered.groups[1].patch.routes[0].destination.number = 67
    #expect(throws:PerformanceGroupTuningConfiguration.ConfigurationError.staleProfile) {
        try loaded.plan(matching:reordered)
    }
    #expect(throws:PerformanceGroupTuningConfiguration.ConfigurationError.staleProfile) {
        try PerformanceGroupTuningConfiguration.read(bytes,matching:reordered)
    }
}

@Test func groupTuningArchiveRejectsLegacyVersionDuplicateAndUnknownGroup() throws {
    let a = tunedGroup(.gamepad1)
    let profile = PerformanceGroupProfile(groups:[a])
    let config = try PerformanceGroupTuningConfiguration(profile:profile,tuning:[a.id:groupTuning(-20)])
    let bytes = try config.archive()
    #expect(throws:Error.self) { try PerformanceGroupProfile.read(bytes) }
    let legacy = try profile.archive()
    #expect(throws:PerformanceGroupTuningConfiguration.ConfigurationError.unsupportedFormat) {
        try PerformanceGroupTuningConfiguration.read(legacy,matching:profile)
    }
    let object = try #require(JSONSerialization.jsonObject(with:bytes) as? [String:Any])
    var wrong = object
    wrong["version"] = 2
    let version = try JSONSerialization.data(withJSONObject:wrong)
    #expect(throws:PerformanceGroupTuningConfiguration.ConfigurationError.unsupportedFormat) {
        try PerformanceGroupTuningConfiguration.read(version,matching:profile)
    }
    let entries = try #require(object["entries"] as? [[String:Any]])
    var duplicate = object
    duplicate["entries"] = entries+entries
    let repeated = try JSONSerialization.data(withJSONObject:duplicate)
    #expect(throws:PerformanceGroupTuningConfiguration.ConfigurationError.duplicateGroup) {
        try PerformanceGroupTuningConfiguration.read(repeated,matching:profile)
    }
    var unknown = object
    var entry = try #require(entries.first)
    entry["groupID"] = UUID().uuidString
    unknown["entries"] = [entry]
    let other = try JSONSerialization.data(withJSONObject:unknown)
    #expect(throws:MIDIClipError.invalidClip) {
        try PerformanceGroupTuningConfiguration.read(other,matching:profile)
    }
}


@Test func groupDAWPreviewUsesWireChannelsAndIndependentPortIdentity() throws {
    let a = tunedGroup(.gamepad1,channel:3)
    let b = tunedGroup(.gamepad2,channel:3)
    let c = tunedGroup(.gamepad3,channel:9)
    let profile = PerformanceGroupProfile(groups:[a,b,c])
    let configuration = try PerformanceGroupTuningConfiguration(profile:profile,
        tuning:[a.id:groupTuning(-20),b.id:groupTuning(20)])
    let preview = try PerformanceGroupDAWProjection(profile:profile,configuration:configuration)
    let first = try #require(preview.groups.first(where:{ $0.id == a.id }))
    let second = try #require(preview.groups.first(where:{ $0.id == b.id }))
    let standard = try #require(preview.groups.first(where:{ $0.id == c.id }))
    #expect(Set(preview.groups.map(\.port)).count == 3)
    #expect(first.port == a.plannedPortName && second.port == b.plannedPortName)
    #expect(first.mode == .lowerMPE && first.masterChannel == 1)
    #expect(first.members.map(\.channel) == [2,3])
    #expect(first.members[0].bend < 8192 && second.members[0].bend > 8192)
    #expect(first.routes.filter { $0.logical.kind == .note }.map(\.channel) == [2,3])
    #expect(first.routes.filter { $0.logical.kind != .note }.map(\.channel) == [1,1])
    #expect(first.routes.allSatisfy { $0.logical.channel == 3 })
    #expect(first.channels == [1,2,3])
    #expect(standard.mode == .standard && standard.masterChannel == nil && standard.members.isEmpty)
    #expect(standard.channels == [10] && standard.routes.allSatisfy { $0.logical == $0.wire })
    let plan = try configuration.plan(matching:profile)
    for group in preview.groups {
        for route in group.routes {
            let item = PerformanceGroupCommand(groupID:group.id,command:.init(route.logical,value:0))
            #expect(plan.translate(item)?.command.destination == route.wire)
        }
    }
}

@Test func groupDAWPreviewNeverFallsBackAfterStaleTuningAndPreservesRename() throws {
    let a = tunedGroup(.gamepad1)
    let b = tunedGroup(.gamepad2)
    let profile = PerformanceGroupProfile(groups:[a,b])
    let configuration = try PerformanceGroupTuningConfiguration(profile:profile,tuning:[a.id:groupTuning(-20)])
    var renamed = profile
    renamed.groups[0].name = "New name"
    renamed.groups.swapAt(0,1)
    let preview = try PerformanceGroupDAWProjection(profile:renamed,configuration:configuration)
    #expect(preview.groups.map(\.id) == [b.id,a.id])
    #expect(preview.groups[1].name == "New name" && preview.groups[1].port == a.plannedPortName)
    #expect(preview.groups[1].mode == .lowerMPE)
    renamed.groups[1].patch.routes[0].destination.number = 67
    #expect(throws:PerformanceGroupTuningConfiguration.ConfigurationError.staleProfile) {
        try PerformanceGroupDAWProjection(profile:renamed,configuration:configuration)
    }
    let explicitlyStandard = try PerformanceGroupDAWProjection(profile:renamed)
    #expect(explicitlyStandard.groups.allSatisfy { $0.mode == .standard })
}


@Test func groupTuningFileBoundsAndExplicitScaleValidation() throws {
    let a = tunedGroup(.gamepad1)
    let profile = PerformanceGroupProfile(groups:[a])
    let scale = try #require(CustomScale.fromDegreeCents("0, 180, 400, 500, 700, 900, 1100, 1200",
                                                       name:"Independent scale"))
    #expect(scale.isMicrotonal)
    #expect(scale.degreeCents == [0,180,400,500,700,900,1100])
    #expect(CustomScale.fromDegreeCents("0, 150, 400",name:"Tie") == nil)
    #expect(CustomScale.fromDegreeCents("0, 180, 180",name:"Duplicate") == nil)
    #expect(CustomScale.fromDegreeCents("0, 400, 180",name:"Unsorted") == nil)
    #expect(CustomScale.fromDegreeCents("0, 180, 1201",name:"Out of range") == nil)
    #expect(CustomScale.fromDegreeCents("0, 180, 400",name:"") == nil)
    let configuration = try PerformanceGroupTuningConfiguration(profile:profile,
        tuning:[a.id:.init(scale:scale,root:60)])
    let encoded = try configuration.archive()
    let decoded = try PerformanceGroupTuningConfiguration.read(encoded,matching:profile)
    #expect(decoded == configuration)
    let oversized = Data(repeating:0,count:WorkspaceArchive.maximumBytes + 1)
    #expect(throws:WorkspaceArchiveError.tooLarge) {
        try PerformanceGroupTuningConfiguration.read(oversized,matching:profile)
    }
    #expect(throws:Error.self) {
        try PerformanceGroupTuningConfiguration.read(Data(encoded.dropLast()),matching:profile)
    }
    #expect(throws:MIDIClipError.invalidClip) {
        try PerformanceGroupTuningConfiguration(profile:profile,
            tuning:[a.id:.init(scale:scale,root:128)])
    }
}
