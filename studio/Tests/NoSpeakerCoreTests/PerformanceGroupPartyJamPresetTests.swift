import Foundation
import Testing
@testable import NoSpeakerCore

@Test func partyJamGroupPresetsStayWithinLimitsAndUseFourDistinctMobileSlots() throws {
    for preset in PerformanceGroupPartyJamPreset.allCases {
        let profile = try #require(preset.makeProfile())
        #expect(profile.isValid && profile.layeredInputs.isEmpty)
        let routes = profile.groups.flatMap { $0.patch.routes }
        #expect(Set(routes.map(\.source).filter { $0.isGroupRemote }) == Set(SensorSource.groupRemoteSources))
        #expect(routes.count <= PerformanceGroupProfile.maximumRoutes)
        #expect(profile.groups.count <= PerformanceGroupProfile.maximumGroups)
        #expect(Set(profile.groups.map(\.plannedPortName)).count == profile.groups.count)
        #expect(PerformanceGroupGamepadSession.supports(profile,allowSurfaces:true,allowRemote:true))
        #expect(!PerformanceGroupGamepadSession.supports(profile,allowSurfaces:true))
        #expect(try PerformanceGroupProfile.read(profile.archive()) == profile)
        let session = try PerformanceGroupGamepadSession(profile:profile,allowSurfaces:true,allowRemote:true)
        let pedal = try #require(session.remoteCapabilities(.tablet2))
        #expect(pedal.pedals == 29 && !pedal.touch && pedal.piano == 0 && pedal.drums == 0)
        if preset == .mobileQuartet {
            #expect(profile.groups.count == 3 && routes.count == 41)
        } else {
            #expect(profile.groups.count == 5 && routes.count == 55)
            #expect(Set(routes.map(\.source)).isSuperset(of:[.gamepad1,.gamepad2,.trackpad,.magicMouse]))
        }
    }
}

@Test func partyJamGroupPresetNeverOverwritesAnExistingDraft() throws {
    var draft = PerformanceGroupProfile()
    let first = PerformanceGroupPartyJamPreset.mobileQuartet.install(in:&draft)
    #expect(first)
    let previous = draft
    let rejected = PerformanceGroupPartyJamPreset.hybridBand.install(in:&draft)
    #expect(!rejected && draft == previous)
}
