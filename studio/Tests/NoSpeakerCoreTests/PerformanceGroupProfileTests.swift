import Foundation
import Testing
@testable import NoSpeakerCore

@Test func groupRenameReorderAndArchiveKeepIdentityAndPort() throws {
    let a = PerformanceInstrumentGroup(name:"Guitar",patch:.starter)
    let b = PerformanceInstrumentGroup(name:"Piano")
    var profile = PerformanceGroupProfile(groups:[a,b])
    profile.groups[0].name = "Lead"
    profile.groups.swapAt(0,1)
    let decoded = try PerformanceGroupProfile.read(profile.archive())
    #expect(decoded == profile)
    #expect(decoded.groups[1].id == a.id)
    #expect(decoded.groups[1].plannedPortName == a.plannedPortName)
    #expect(decoded.groups[0].plannedPortName == b.plannedPortName)
    #expect(a.plannedPortName != b.plannedPortName)
}

@Test func groupCopyKeepsMappingsButCannotReuseIdentity() {
    let original = PerformanceInstrumentGroup(name:"Bass",patch:.starter)
    var profile = PerformanceGroupProfile(groups:[original])
    let newID = UUID()
    let copied = profile.duplicate(original.id,newID:newID)
    #expect(copied)
    #expect(profile.groups.count == 2)
    #expect(profile.groups[1].id == newID)
    #expect(profile.groups[1].patch == original.patch)
    #expect(profile.groups[1].plannedPortName != original.plannedPortName)
    let before = profile
    let duplicate = profile.duplicate(original.id,newID:newID)
    #expect(!duplicate)
    #expect(profile == before)
}

@Test func groupRejectsInvalidNamesDuplicateIDsAndCapacityAtomically() throws {
    let original = PerformanceInstrumentGroup(name:"Keys")
    var profile = PerformanceGroupProfile(groups:[original])
    let duplicate = profile.add(.init(id:original.id,name:"Other"))
    #expect(!duplicate)
    for name in ["", "   ", "Line\nBreak", String(repeating:"x",count:129)] {
        let added = profile.add(.init(name:name))
        #expect(!added)
    }
    for _ in 1..<PerformanceGroupProfile.maximumGroups {
        let added = profile.add(.init(name:"Keys"))
        #expect(added)
    }
    let before = profile
    let overflow = profile.add(.init(name:"Overflow"))
    #expect(!overflow)
    #expect(profile == before)
    var invalid = profile
    invalid.groups.append(original)
    #expect(!invalid.isValid)
    let raw = try WorkspaceArchive.encode(name:"Invalid",payload:invalid)
    #expect(throws: WorkspaceArchiveError.invalidPayload) { try PerformanceGroupProfile.read(raw) }
}

@Test func groupRouteBudgetIsGlobalAndCopyIsAtomic() {
    let routes = (0..<PerformanceGroupProfile.maximumRoutes).map {
        SensorMapping(id:"note"+String($0),source:.trackpad,signal:.contact,
                      destination:.init(.note,number:$0))
    }
    let patch = InstrumentPatch(name:"Capacity",routes:routes)
    #expect(patch.isValid)
    let group = PerformanceInstrumentGroup(name:"Layer",patch:patch)
    var profile = PerformanceGroupProfile(groups:[group])
    #expect(profile.isValid)
    let before = profile
    let duplicate = profile.duplicate(group.id)
    #expect(!duplicate)
    #expect(profile == before)
    let empty = profile.add(.init(name:"Empty"))
    #expect(empty)
}

@Test func groupLayeringDetectsSharedSignalsNotSameDeviceAlone() {
    let a = PerformanceInstrumentGroup(name:"A",patch:.init(routes:[
        .init(id:"note",source:.gamepad1,signal:.padA,destination:.init(.note,number:60)),
        .init(id:"chord",source:.gamepad1,signal:.padA,destination:.init(.note,number:64))
    ]))
    let b = PerformanceInstrumentGroup(name:"B",patch:.init(routes:[
        .init(id:"note",source:.gamepad1,signal:.padA,destination:.init(.note,number:48)),
        .init(id:"effect",source:.gamepad1,signal:.padLSX,destination:.init(.controlChange,number:74))
    ]))
    let profile = PerformanceGroupProfile(groups:[a,b])
    #expect(profile.isValid)
    #expect(profile.layeredInputs == [.init(source:.gamepad1,signal:.padA)])
    let single = PerformanceGroupProfile(groups:[a])
    #expect(single.layeredInputs.isEmpty)
}
