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

@Test func mobileDraftRejectsStaleSourceConflictsAndThirdFamily() throws {
    let profile = mobileDraftFixture()
    var draft = try PerformanceGroupMobileDraft(profile:profile,groupID:profile.groups[0].id,source:.phone2)
    var changed = profile
    changed.groups[1].name = "Changed elsewhere"
    #expect(throws:PerformanceGroupMobileDraft.EditError.staleProfile) { try draft.applying(to:changed) }
    let added = draft.append(.drumPad1)
    #expect(added)
    #expect(throws:PerformanceGroupMobileDraft.EditError.unsupportedSurface) { try draft.applying(to:profile) }
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
    #expect(!draft.duplicateMapping("missing",newID:"third"))
    #expect(!draft.duplicateMapping("root",newID:"root"))
    #expect(!draft.duplicateMapping("root",newID:""))
    #expect(draft.duplicateMapping("root",newID:"third"))
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
    #expect(!draft.duplicateMapping("mobile",newID:"local"))
    #expect(draft.duplicateMapping("mobile",newID:"second"))
    draft.routes[1].destination.number = 65
    #expect(draft.remainingRouteCapacity==0)
    #expect(draft.availableSignals.isEmpty)
    #expect(!draft.append(.x))
    #expect(!draft.duplicateMapping("mobile"))
    let applied = try draft.applying(to:profile)
    #expect(applied.groups[1]==profile.groups[1])
    #expect(applied.groups.reduce(0) { $0+$1.patch.routes.count }==PerformanceGroupProfile.maximumRoutes)
    draft.routes.removeLast()
    #expect(draft.remainingRouteCapacity==1)
}
