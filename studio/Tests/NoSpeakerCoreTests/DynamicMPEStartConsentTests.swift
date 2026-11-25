import Foundation
import Testing
@testable import NoSpeakerCore

@Test func dynamicConsentBindsArchiveTuningDevicesAndLayering() throws {
    let group = PerformanceInstrumentGroup(name:"Lead",patch:.init(routes:[
        .init(id:"note",source:.gamepad1,signal:.padA,destination:.init(.note,number:62))
    ]))
    let profile = PerformanceGroupProfile(groups:[group])
    let spec = try DynamicMPEPreview.specification(name:"Wide",degrees:"0, 220, 400, 500, 700, 900, 1100",rootText:"60")
    let archive = try profile.archive()
    let controller = UUID()
    func consent(profile:PerformanceGroupProfile = profile,
                 tuning:[UUID:PerformanceGroupTuningPlan.Specification] = [group.id:spec],
                 archive:Data = archive,controller:UUID = controller,layering:Bool = false,
                 camera:String = "camera",mirror:Bool = false) -> DynamicMPEStartConsent {
        .init(profile:profile,tuning:tuning,archive:archive,controllers:[.gamepad1:controller],
              allowLayering:layering,cameraID:camera,cameraOrientation:.upright,
              cameraMirror:mirror,mouseOrientation:.horizontal)
    }
    let baseline = consent()
    #expect(baseline == consent())
    #expect(baseline != consent(archive:Data()))
    #expect(baseline != consent(controller:UUID()))
    #expect(baseline != consent(layering:true))
    #expect(baseline != consent(camera:"other"))
    #expect(baseline != consent(mirror:true))
    #expect(baseline != consent(tuning:[:]))
    var changed = profile
    changed.groups[0].name = "Other"
    #expect(baseline != consent(profile:changed))
}
