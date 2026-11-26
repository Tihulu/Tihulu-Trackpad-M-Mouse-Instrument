import Foundation
import Testing
@testable import NoSpeakerCore

private func mobileDraftFixture() -> PerformanceGroupProfile {
    .init(groups:[
        .init(name:"Lead",patch:.init(routes:[
            .init(id:"local",source:.gamepad1,signal:.padA,destination:.init(.note,number:64)),
            .init(id:"mobile",source:.phone2,signal:.contact,destination:.init(.note,number:60))
        ],performanceLayout:.init(widgets:[.init(source:.gamepad1,signal:.padA,label:"Keep"),.init(source:.phone2,signal:.contact,label:"Lead")]))),
        .init(name:"Pedals",patch:.init(routes:[.init(id:"pedal",source:.phone2,signal:.pedalSustain,destination:.init(.sustain))]))
    ])
}

@Test func mobileDraftPreservesUnrelatedRoutesPortAndLabels() throws {
    let profile = mobileDraftFixture(), original = profile.groups[0]
    var draft = try PerformanceGroupMobileDraft(profile:profile,groupID:original.id,source:.phone2)
    let added = draft.append(.x)
    #expect(added)
    draft.routes[0].destination.number = 62
    draft.widgets[0].label = "New lead"
    let next = try draft.applying(to:profile)
    #expect(next.groups[0].id == original.id && next.groups[0].plannedPortName == original.plannedPortName)
    #expect(next.groups[0].patch.routes[0] == original.patch.routes[0])
    #expect(next.groups[0].patch.routes[1].id == "mobile")
    #expect(next.groups[0].patch.routes[1].destination.number == 62)
    #expect(next.groups[0].patch.performanceLayout?.widgets[0].label == "Keep")
    #expect(next.groups[0].patch.performanceLayout?.widgets[1].label == "New lead")
    #expect(next.groups[1] == profile.groups[1])
    #expect(try PerformanceGroupProfile.read(next.archive()) == next)
}

@Test func mobileDraftRejectsStaleSourceConflictsAndUnsupportedSignal() throws {
    let profile = mobileDraftFixture()
    var draft = try PerformanceGroupMobileDraft(profile:profile,groupID:profile.groups[0].id,source:.phone2)
    var changed = profile
    changed.groups[1].name = "Changed elsewhere"
    #expect(throws:PerformanceGroupMobileDraft.EditError.staleProfile) { try draft.applying(to:changed) }
    let added = draft.append(.drumPad1)
    #expect(added)
    let third = try draft.applying(to:profile)
    #expect(PerformanceGroupGamepadSession.supports(third,allowRemote:true))
    #expect(third.groups[1] == profile.groups[1])
    draft.routes[draft.routes.count-1].signal = .pressure
    #expect(throws:PerformanceGroupMobileDraft.EditError.invalidMapping) { try draft.applying(to:profile) }
    draft.routes.removeLast()
    draft.routes[0].source = .tablet
    #expect(throws:PerformanceGroupMobileDraft.EditError.invalidMapping) { try draft.applying(to:profile) }
}

@Test func mobileDraftRejectsUnsafeGainSelectorsAndDuplicateIDs() throws {
    let profile = mobileDraftFixture()
    var draft = try PerformanceGroupMobileDraft(profile:profile,groupID:profile.groups[0].id,source:.phone2)
    draft.routes[0].destination = .init(.controlChange,number:7)
    #expect(throws:PerformanceGroupMobileDraft.EditError.invalidMapping) { try draft.applying(to:profile) }
    draft.routes[0].response = .init(release:0)
    _ = try draft.applying(to:profile)
    draft.routes[0].destination = .init(.controlChange,number:101)
    #expect(throws:PerformanceGroupMobileDraft.EditError.invalidMapping) { try draft.applying(to:profile) }
    draft.routes[0].destination = .init(.controlChange,number:7)
    draft.routes.append(draft.routes[0])
    #expect(throws:PerformanceGroupMobileDraft.EditError.capacityOrConflict) { try draft.applying(to:profile) }
}

@Test func mobileDraftAllowsEmptySlotAndExplicitRemovalWithoutTouchingSiblings() throws {
    let profile = mobileDraftFixture()
    var draft = try PerformanceGroupMobileDraft(profile:profile,groupID:profile.groups[0].id,source:.tablet2)
    #expect(draft.routes.isEmpty)
    let added = draft.append(.pedalVolume)
    #expect(added && draft.routes[0].response?.release == 0)
    let widget = draft.addWidget(.pedalVolume)
    #expect(widget)
    let next = try draft.applying(to:profile)
    #expect(next.groups[0].patch.routes.count == 3 && next.groups[1] == profile.groups[1])
    var remove = try PerformanceGroupMobileDraft(profile:next,groupID:next.groups[0].id,source:.tablet2)
    remove.routes = []
    let removed = try remove.applying(to:next)
    #expect(removed.groups[0].patch.routes == profile.groups[0].patch.routes)
    #expect(removed.groups[1] == profile.groups[1])
}


@Test func mobileDraftNoOpPreservesInterleavedLayoutAndRejectsConflictingWidget() throws {
    var profile = mobileDraftFixture()
    profile.groups[0].patch.performanceLayout = .init(widgets:[
        .init(source:.phone2,signal:.contact,label:"Lead"),
        .init(source:.gamepad1,signal:.padA,label:"Keep"),
        .init(source:.phone2,signal:.x,label:"Dormant")
    ])
    var draft = try PerformanceGroupMobileDraft(profile:profile,groupID:profile.groups[0].id,source:.phone2)
    #expect(try draft.applying(to:profile) == profile)
    draft.widgets.swapAt(0,1)
    let next = try draft.applying(to:profile)
    #expect(next.groups[0].patch.performanceLayout?.widgets.map(\.label) == ["Dormant","Keep","Lead"])
    draft.widgets.append(draft.widgets[0])
    #expect(throws:PerformanceGroupMobileDraft.EditError.capacityOrConflict) { try draft.applying(to:profile) }
}

@Test func mobileDraftExplicitLayeredTargetPreservesScopedNoteGate() throws {
    let group = PerformanceInstrumentGroup(name:"Mobile chords",patch:.init(routes:[
        .init(id:"root",source:.phone2,signal:.contact,destination:.init(.note,number:60))
    ]))
    let profile = PerformanceGroupProfile(groups:[group])
    var draft = try PerformanceGroupMobileDraft(profile:profile,groupID:group.id,source:.phone2)
    let mutation1 = draft.duplicateMapping("missing",newID:"third")
    #expect(!mutation1)
    let mutation2 = draft.duplicateMapping("root",newID:"root")
    #expect(!mutation2)
    let mutation3 = draft.duplicateMapping("root",newID:"")
    #expect(!mutation3)
    let mutation4 = draft.duplicateMapping("root",newID:"third")
    #expect(mutation4)
    #expect(draft.routes.count==2 && draft.routes[1].signal == .contact)
    draft.routes[1].destination.number = 64
    let next = try draft.applying(to:profile)
    #expect(next.groups[0].id==group.id && next.groups[0].patch.routes[0]==group.patch.routes[0])
    #expect(try PerformanceGroupProfile.read(next.archive())==next)

    var session = try PerformanceGroupGamepadSession(profile:next,allowRemote:true)
    let token = try session.bind(.phone2,now:0)
    var events:[PerformanceGroupCommand] = []
    let sink:(PerformanceGroupCommand)->Bool = { events.append($0); return true }
    func frame(_ text:String)->Data { Data(text.utf8) }
    _ = session.receiveRemote(.phone2,token:token,bytes:frame(#"{"kind":"release","version":1,"sequence":1}"#),hostTime:0,now:0,send:sink)
    _ = session.receiveRemote(.phone2,token:token,bytes:frame(#"{"kind":"touch","version":1,"sequence":2,"x":0.5,"y":0.5}"#),hostTime:0.01,now:0.01,send:sink)
    #expect(events.count==2)
    #expect(Set(events.filter { $0.command.value>0 }.map { $0.command.destination.number }) == [60,64])
    events.removeAll()
    _ = session.receiveRemote(.phone2,token:token,bytes:frame(#"{"kind":"release","version":1,"sequence":3}"#),hostTime:0.02,now:0.02,send:sink)
    #expect(events.count==2)
    #expect(Set(events.filter { $0.command.value==0 }.map { $0.command.destination.number }) == [60,64])
    #expect(events.allSatisfy { $0.groupID==group.id })
}

@Test func mobileDraftTargetCapacityAccountsForOtherGroupsAndIDs() throws {
    var profile = mobileDraftFixture()
    let extra = PerformanceGroupProfile.maximumRoutes-4
    for index in 0..<extra {
        profile.groups[1].patch.routes.append(.init(id:"extra-\(index)",source:.phone2,signal:.pedalSustain,destination:.init(.sustain)))
    }
    #expect(profile.isValid)
    var draft = try PerformanceGroupMobileDraft(profile:profile,groupID:profile.groups[0].id,source:.phone2)
    #expect(draft.remainingRouteCapacity==1)
    let mutation5 = draft.duplicateMapping("mobile",newID:"local")
    #expect(!mutation5)
    let mutation6 = draft.duplicateMapping("mobile",newID:"second")
    #expect(mutation6)
    draft.routes[1].destination.number = 65
    #expect(draft.remainingRouteCapacity==0)
    #expect(draft.availableSignals.isEmpty)
    let mutation7 = draft.append(.x)
    #expect(!mutation7)
    let mutation8 = draft.duplicateMapping("mobile")
    #expect(!mutation8)
    let applied = try draft.applying(to:profile)
    #expect(applied.groups[1]==profile.groups[1])
    #expect(applied.groups.reduce(0) { $0+$1.patch.routes.count }==PerformanceGroupProfile.maximumRoutes)
    draft.routes.removeLast()
    #expect(draft.remainingRouteCapacity==1)
}

@Test func mobileDraftFamilyFillIsAtomicAndPreservesExistingMapping() throws {
    let group = PerformanceInstrumentGroup(name:"Combo",patch:.init(routes:[
        .init(id:"custom",source:.phone,signal:.x,destination:.init(.controlChange,number:71))
    ]))
    let profile = PerformanceGroupProfile(groups:[group])
    var draft = try PerformanceGroupMobileDraft(profile:profile,groupID:group.id,source:.phone)
    let mutation9 = draft.appendFamily(.xy)
    #expect(mutation9)
    #expect(draft.routes.count==3 && draft.routes[0]==group.patch.routes[0])
    let mutation10 = draft.appendFamily(.xy)
    #expect(!mutation10)
    let mutation11 = draft.appendFamily(.drums)
    #expect(mutation11)
    let snapshot=draft.routes
    let mutation12 = draft.appendFamily(.piano)
    #expect(mutation12)
    #expect(Array(draft.routes.prefix(snapshot.count))==snapshot)
    let fourth = draft.appendFamily(.pedalboard)
    #expect(fourth)
    let all = draft.routes
    let duplicate = draft.appendFamily(.pedalboard)
    #expect(!duplicate && draft.routes==all)
    let next=try draft.applying(to:profile)
    #expect(PerformanceGroupGamepadSession.supports(next,allowRemote:true))
    #expect(try PerformanceGroupProfile.read(next.archive())==next)
}

@Test func mobileDraftFamilyFillRespectsSiblingAssignmentsAndRefusesPartialCapacity() throws {
    let lead = PerformanceInstrumentGroup(name:"Lead",patch:.init(routes:[
        .init(id:"x",source:.phone,signal:.x,destination:.init(.pitchBend))
    ]))
    let sibling = PerformanceInstrumentGroup(name:"Pedal",patch:.init(routes:[
        .init(id:"pedal",source:.phone,signal:.pedalSustain,destination:.init(.sustain))
    ]))
    let profile=PerformanceGroupProfile(groups:[lead,sibling])
    var draft=try PerformanceGroupMobileDraft(profile:profile,groupID:lead.id,source:.phone)
    let mutation13 = draft.appendFamily(.drums)
    #expect(mutation13)
    #expect(draft.routes.first==lead.patch.routes.first)
    let expanded = try draft.applying(to:profile)
    #expect(expanded.groups[1] == sibling)
    var full=profile
    for i in 0..<(PerformanceGroupProfile.maximumRoutes-3) {
        full.groups[1].patch.routes.append(.init(id:"f-\(i)",source:.phone,signal:.pedalSustain,destination:.init(.sustain)))
    }
    #expect(full.isValid)
    draft=try PerformanceGroupMobileDraft(profile:full,groupID:lead.id,source:.phone)
    #expect(draft.remainingRouteCapacity==1)
    let mutation14 = draft.appendFamily(.xy)
    #expect(!mutation14)
    #expect(draft.routes==lead.patch.routes)
}

@Test func mobileDraftTargetKindChoicesRespectFixedSurfaceAndCalibration() throws {
    #expect(PerformanceGroupMobileDraft.allowedTargetKinds(for:.drumPad1)==[.note])
    #expect(PerformanceGroupMobileDraft.allowedTargetKinds(for:.pianoSustain)==[.sustain])
    #expect(PerformanceGroupMobileDraft.allowedTargetKinds(for:.pedalSwitch1)==[.controlChange])
    #expect(Set(PerformanceGroupMobileDraft.allowedTargetKinds(for:.pedalExpression))==[.controlChange,.pitchBend])
    #expect(PerformanceGroupMobileDraft.allowedTargetKinds(for:.pressure).isEmpty)
    let group=PerformanceInstrumentGroup(name:"Drum",patch:.init(routes:[
        .init(id:"d",source:.phone,signal:.drumPad1,destination:.init(.note,channel:9,number:36))
    ]))
    let profile=PerformanceGroupProfile(groups:[group])
    var draft=try PerformanceGroupMobileDraft(profile:profile,groupID:group.id,source:.phone)
    draft.routes[0].calibration.inverted=true
    #expect(throws:PerformanceGroupMobileDraft.EditError.invalidMapping) { try draft.applying(to:profile) }
    draft.routes[0].calibration = .init(minimum:0.1,maximum:0.9,deadZone:0.1,exponent:2)
    draft.routes[0].threshold=0.7
    draft.routes[0].hysteresis=0.1
    let result=try draft.applying(to:profile)
    #expect(result.groups[0].patch.routes[0]==draft.routes[0])
}

@Test func mobileDraftRetargetNormalizesKindAndRefusesReservedNumbers() throws {
    let group=PerformanceInstrumentGroup(name:"XY",patch:.init(routes:[
        .init(id:"x",source:.phone,signal:.x,destination:.init(.controlChange,channel:3,number:74),
              response:.init(minimum:0.2,maximum:0.8,smoothingMS:20,release:0.5))
    ]))
    let profile=PerformanceGroupProfile(groups:[group])
    var draft=try PerformanceGroupMobileDraft(profile:profile,groupID:group.id,source:.phone)
    let bad=draft.retarget("x",kind:.controlChange,number:101)
    #expect(!bad && draft.routes==group.patch.routes)
    let note=draft.retarget("x",kind:.note)
    #expect(note && draft.routes[0].destination == .init(.note,channel:3,number:60))
    #expect(draft.routes[0].response == nil)
    let bend=draft.retarget("x",kind:.pitchBend)
    #expect(bend && draft.routes[0].destination == .init(.pitchBend,channel:3))
    let gain=draft.retarget("x",kind:.controlChange,number:7)
    #expect(gain && draft.routes[0].response?.release==0)
    let result=try draft.applying(to:profile)
    #expect(result.groups[0].patch.routes==draft.routes)
}

@Test func mobileDraftRetargetKeepsBinaryAndPianoSurfaceRules() throws {
    let group=PerformanceInstrumentGroup(name:"Keys and switch",patch:.init(routes:[
        .init(id:"key",source:.phone,signal:.pianoKey0,destination:.init(.note,number:48)),
        .init(id:"switch",source:.phone,signal:.pedalSwitch1,destination:.init(.controlChange,number:80))
    ]))
    let profile=PerformanceGroupProfile(groups:[group])
    var draft=try PerformanceGroupMobileDraft(profile:profile,groupID:group.id,source:.phone)
    let old=draft.routes
    let wrong=draft.retarget("key",kind:.pitchBend)
    let gain=draft.retarget("switch",kind:.controlChange,number:11)
    #expect(!wrong && !gain && draft.routes==old)
    #expect(!PerformanceGroupMobileDraft.allowedTargetNumbers(for:.pedalSwitch1,kind:.controlChange).contains(7))
    #expect(!PerformanceGroupMobileDraft.allowedTargetNumbers(for:.x,kind:.controlChange).contains(64))
    let changed=draft.retarget("switch",kind:.controlChange,number:81)
    #expect(changed)
    let result=try draft.applying(to:profile)
    #expect(result.groups[0].patch.routes==draft.routes)
}

@Test func mobileDraftBulkChannelAndTransposePreserveOtherSlotsAndControls() throws {
    let group=PerformanceInstrumentGroup(name:"Mixed",patch:.init(routes:[
        .init(id:"key",source:.phone,signal:.pianoKey0,destination:.init(.note,channel:1,number:48)),
        .init(id:"pedal",source:.phone,signal:.pianoSustain,destination:.init(.sustain,channel:1)),
        .init(id:"x",source:.phone,signal:.x,destination:.init(.pitchBend)),
        .init(id:"other",source:.tablet,signal:.pianoKey0,destination:.init(.note,number:60))
    ]))
    let sibling=PerformanceInstrumentGroup(name:"Sibling",patch:.init(routes:[
        .init(id:"key",source:.phone,signal:.pianoKey1,destination:.init(.note,number:49))
    ]))
    let profile=PerformanceGroupProfile(groups:[group,sibling])
    var draft=try PerformanceGroupMobileDraft(profile:profile,groupID:group.id,source:.phone)
    let changed=draft.transformFamily(.piano,channel:4,transpose:12)
    #expect(changed)
    let next=try draft.applying(to:profile)
    let routes=next.groups[0].patch.routes
    #expect(routes[0].destination == .init(.note,channel:4,number:60))
    #expect(routes[1].destination == .init(.sustain,channel:4))
    #expect(routes[2...]==group.patch.routes[2...])
    #expect(routes.map(\.id)==group.patch.routes.map(\.id))
    #expect(next.groups[1]==sibling)
    #expect(try PerformanceGroupProfile.read(next.archive())==next)
}

@Test func mobileDraftBulkTransposeRejectsEntireOperationOnPitchOverflow() throws {
    let group=PerformanceInstrumentGroup(name:"Piano",patch:.init(routes:[
        .init(id:"first",source:.phone,signal:.pianoKey0,destination:.init(.note,number:60)),
        .init(id:"last",source:.phone,signal:.pianoKey1,destination:.init(.note,number:127))
    ]))
    let profile=PerformanceGroupProfile(groups:[group])
    var draft=try PerformanceGroupMobileDraft(profile:profile,groupID:group.id,source:.phone)
    let overflow=draft.transformFamily(.piano,channel:6,transpose:1)
    let badChannel=draft.transformFamily(.piano,channel:16)
    let badTranspose=draft.transformFamily(.piano,transpose:Int.max)
    let absent=draft.transformFamily(.drums,channel:4)
    let noChange=draft.transformFamily(.piano,channel:0)
    #expect(!overflow && !badChannel && !badTranspose && !absent && !noChange)
    #expect(draft.routes==group.patch.routes)
    let changed=draft.transformFamily(.piano,transpose:-12)
    #expect(changed && draft.routes.map(\.destination.number)==[48,115])
}

@Test func measuredXYZPresetKeepsOtherPlayersAndRejectsTargetCollisions() throws {
    let group = PerformanceInstrumentGroup(name: "Keys", patch: .init(routes: [
        .init(id: "keys", source: .tablet, signal: .pianoKey0, destination: .init(.note, number: 60))
    ]))
    let profile = PerformanceGroupProfile(groups: [group])
    var draft = try PerformanceGroupMobileDraft(profile: profile, groupID: group.id, source: .phone)
    let conflicting = draft.addXYZHelper(.expression, channel: 0)
    #expect(!conflicting && draft.routes.isEmpty)
    let added = draft.addXYZHelper(.expression, channel: 1)
    #expect(added && draft.xyzHelperIsCompatible)
    #expect(try draft.applying(to: profile).groups[0].patch.routes.first == group.patch.routes.first)
    draft.routes[1].destination = draft.routes[2].destination
    #expect(!draft.xyzHelperIsCompatible)
}

@Test func measuredAxisSensitivityPreservesLegacyCalibrationAndCenter() throws {
    var calibration = try JSONDecoder().decode(SensorCalibration.self, from:
        Data(#"{"minimum":0,"maximum":1,"inverted":false,"deadZone":0,"exponent":1}"#.utf8))
    #expect(calibration.apply(0.25) == 0.25)
    calibration.sensitivity = 2
    #expect(calibration.apply(0.25) == 0 && calibration.apply(0.5) == 0.5 && calibration.apply(1) == 1)
    calibration.sensitivity = .nan
    #expect(calibration.apply(0.5) == nil)
}
