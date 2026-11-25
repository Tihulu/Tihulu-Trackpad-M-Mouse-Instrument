import Foundation
import Testing
@testable import NoSpeakerCore

@Test func dynamicActivationRequiresExplicitConfirmationAndCleanLocalPorts() throws {
    var scale = CustomScale()
    scale.centOffsets = [2:20]
    let group = PerformanceInstrumentGroup(name:"Lead",patch:.init(routes:[
        .init(id:"note",source:.gamepad1,signal:.padA,destination:.init(.note,number:62))
    ]))
    let profile = PerformanceGroupProfile(groups:[group])
    let tuning:[UUID:PerformanceGroupTuningPlan.Specification] = [group.id:.init(scale:scale,root:60)]
    func plan(confirmed:Bool = true,registered:Set<UUID> = [],cleanup:Set<UUID> = [],disposal:Int = 0,
              remote:Bool = false,haptics:Set<UUID> = []) throws -> DynamicMPEActivationPlan {
        try .init(profile:profile,tuning:tuning,confirmed:confirmed,allowLayering:false,
            registeredIDs:registered,cleanupIDs:cleanup,pendingDisposalCount:disposal,allowRemote:remote,hapticGroups:haptics)
    }
    #expect(throws:DynamicMPEActivationPlan.AdmissionError.confirmationRequired) { try plan(confirmed:false) }
    #expect(throws:DynamicMPEActivationPlan.AdmissionError.cleanupRequired) { try plan(cleanup:[group.id]) }
    #expect(throws:DynamicMPEActivationPlan.AdmissionError.cleanupRequired) { try plan(disposal:1) }
    #expect(throws:DynamicMPEActivationPlan.AdmissionError.portsMustBeClosed) { try plan(registered:[group.id]) }
    #expect(throws:DynamicMPEActivationPlan.AdmissionError.incompatibleMode) { try plan(remote:true) }
    #expect(throws:DynamicMPEActivationPlan.AdmissionError.incompatibleMode) { try plan(haptics:[group.id]) }
    let accepted = try plan()
    #expect(accepted.preview.profile == profile && accepted.preview.tuning == tuning)
}
