import Foundation
import Testing
@testable import NoSpeakerCore

@Test func groupEndpointPlanIdentitySurvivesArchiveRenameAndReorder() throws {
    let a = PerformanceInstrumentGroup(name:"Lead",patch:.starter)
    let b = PerformanceInstrumentGroup(name:"Keys",patch:.starter)
    let empty = PerformanceInstrumentGroup(name:"Empty")
    var profile = PerformanceGroupProfile(groups:[a,b,empty])
    let plan = try PerformanceGroupEndpointPlan(profile:profile)
    #expect(plan.entries.count == 2)
    #expect(plan.entries.allSatisfy { $0.uniqueID > 0 })
    profile.groups[0].name = "Renamed"
    profile.groups.reverse()
    let restored = try PerformanceGroupProfile.read(profile.archive())
    let next = try PerformanceGroupEndpointPlan(profile:restored)
    #expect(next == plan)
    #expect(plan.permitsRegistration(occupied:[]))
    #expect(!plan.permitsRegistration(occupied:Set(plan.entries.map(\.uniqueID))))
}

@Test func groupEndpointPlanRejectsRealHashCollisionRatherThanRemapping() throws {
    let id1 = try #require(UUID(uuidString:"12345678-1234-4321-8888-0000db9bf43f"))
    let id2 = try #require(UUID(uuidString:"12345678-1234-4321-8888-000032939107"))
    #expect(id1 != id2)
    #expect(PerformanceGroupEndpointPlan.uniqueID(id1) == 219825602)
    #expect(PerformanceGroupEndpointPlan.uniqueID(id2) == 219825602)
    let profile = PerformanceGroupProfile(groups:[
        .init(id:id1,name:"A",patch:.starter),
        .init(id:id2,name:"B",patch:.starter)
    ])
    #expect(profile.isValid)
    #expect(throws: PerformanceGroupEndpointPlan.EndpointError.identityCollision) {
        try PerformanceGroupEndpointPlan(profile:profile)
    }
}

@Test func groupEndpointPlanEmptyOrInvalidDoesNotReservePorts() {
    #expect(throws: PerformanceGroupRouterError.invalidProfile) {
        try PerformanceGroupEndpointPlan(profile:.init())
    }
    #expect(throws: PerformanceGroupRouterError.invalidProfile) {
        try PerformanceGroupEndpointPlan(profile:.init(groups:[.init(name:"Empty")]))
    }
}
