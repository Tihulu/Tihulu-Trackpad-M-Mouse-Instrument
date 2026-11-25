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
