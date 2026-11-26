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


@Test func groupStarterCatalogHasExactRequirementsAndEditableIndependentCopies() throws {
    for preset in PerformanceGroupStarterPreset.allCases {
        var profile=try #require(preset.makeProfile())
        let copy=try #require(preset.makeProfile())
        #expect(Set(profile.groups.flatMap { $0.patch.routes.map(\.source) }) == Set(preset.requiredSources))
        #expect(profile.isValid && profile.layeredInputs.isEmpty)
        #expect(Set(profile.groups.map(\.id)).isDisjoint(with:Set(copy.groups.map(\.id))))
        #expect(PerformanceGroupGamepadSession.supports(profile,allowSurfaces:true,allowScalars:true,allowCamera:true,allowRemote:preset.requiresMobile))
        #expect(try PerformanceGroupProfile.read(profile.archive()) == profile)
        profile.groups[0].name="My instrument"
        #expect(profile.isValid && copy.groups[0].name != "My instrument")
        #expect(try PerformanceGroupProfile.read(profile.archive()) == profile)
        let session=try PerformanceGroupGamepadSession(profile:profile,allowSurfaces:true,allowScalars:true,allowCamera:true,allowRemote:preset.requiresMobile)
        #expect(session.boundSources.isEmpty)
    }
}

@Test func groupStarterAppendProtectsExistingMappingsAndCapacity() throws {
    let a=try #require(PerformanceGroupStarterPreset.trackpadSolo.makeProfile())
    let b=try #require(PerformanceGroupStarterPreset.xboxSolo.appending(to:a))
    #expect(b.groups.count==2 && b.groups.first==a.groups.first)
    #expect(PerformanceGroupStarterPreset.trackpadSolo.appending(to:b)==nil)
    #expect(PerformanceGroupStarterPreset.hybridBand.appending(to:b)==nil)
    let full=PerformanceGroupProfile(groups:(0..<PerformanceGroupProfile.maximumGroups).map { .init(name:"Empty "+String($0)) })
    #expect(PerformanceGroupStarterPreset.phoneSolo.appending(to:full)==nil)
}


@Test func readyToPlayHelperPresetsShareOnePortAndKeepSustainWithLead() throws {
    for preset in [PerformanceGroupStarterPreset.mousePedal,.xboxHelper,.phonePedals] {
        let profile=try #require(preset.makeProfile())
        let group=try #require(profile.groups.first)
        #expect(profile.groups.count==1)
        let routes=group.patch.routes
        let note=try #require(routes.first(where:{$0.destination.kind == .note}))
        let sustain=try #require(routes.first(where:{$0.destination.kind == .sustain}))
        #expect(note.source == .trackpad && sustain.source != .trackpad)
        #expect(note.destination.channel==sustain.destination.channel)
        var router=try PerformanceGroupRouter(profile:profile)
        let lead=try router.connect(note.source,now:1)
        let helper=try router.connect(sustain.source,now:1)
        let attack=router.frame(lease:lead,sequence:1,now:1,values:[note.signal:1])
        let pedal=router.frame(lease:helper,sequence:1,now:1.1,values:[sustain.signal:1])
        let lift=router.disconnect(lead)
        let release=router.disconnect(helper)
        #expect(attack.map(\.command)==[.init(note.destination,value:100)])
        #expect(pedal.map(\.command)==[.init(sustain.destination,value:127)])
        #expect(lift.map(\.command)==[.init(note.destination,value:0)])
        #expect(release.map(\.command)==[.init(sustain.destination,value:0)])
    }
}


@Test func switchableMobilePresetsAdvertiseOnlyTheirAssignedFamilies() throws {
    for preset in [PerformanceGroupStarterPreset.phoneXYKeys,.tabletKeysDrums,.phoneXYEffects] {
        let profile=try #require(preset.makeProfile())
        let source=try #require(preset.requiredSources.first)
        let session=try PerformanceGroupGamepadSession(profile:profile,allowRemote:true)
        let caps=try #require(session.remoteCapabilities(source))
        #expect(!caps.tilt && !caps.rotation && !caps.acceleration)
        switch preset {
        case .phoneXYKeys: #expect(caps.touch && caps.piano==RemotePiano.maximumMask && caps.drums==0 && caps.pedals==0)
        case .tabletKeysDrums: #expect(!caps.touch && caps.piano==RemotePiano.maximumMask && caps.drums==255 && caps.pedals==0)
        case .phoneXYEffects: #expect(caps.touch && caps.piano==0 && caps.drums==0 && caps.pedals==29)
        default: break
        }
    }
}


@Test func allSurfaceMobilePresetsKeepDrumsOnSeparatePortAndSafeMappedControls() throws {
    for preset in [PerformanceGroupStarterPreset.phoneAllSurfaces,.tabletAllSurfaces] {
        let profile=try #require(preset.makeProfile())
        let source=try #require(preset.requiredSources.first)
        #expect(profile.groups.count == 2 && profile.layeredInputs.isEmpty)
        let lead=profile.groups[0].patch.routes
        let drums=profile.groups[1].patch.routes
        #expect(drums.count == 8 && drums.allSatisfy { $0.source == source && $0.destination.channel == 9 })
        #expect(lead.contains { $0.signal == .pedalExpression && $0.destination.kind == .pitchBend })
        #expect(lead.contains { $0.signal == .pedalSustain && $0.destination.kind == .sustain })
        #expect(lead.allSatisfy { PerformanceGroupGamepadSession.permitsLiveControl($0) })
        let session=try PerformanceGroupGamepadSession(profile:profile,allowRemote:true)
        let caps=try #require(session.remoteCapabilities(source))
        #expect(caps.touch && caps.piano == RemotePiano.maximumMask && caps.drums == 255 && caps.pedals == 29)
        #expect(!caps.tilt && !caps.rotation && !caps.acceleration && session.boundSources.isEmpty)
    }
}


@Test func dualPhoneStickPresetSharesDrumPortWithDistinctScopedMasks() throws {
    let profile=try #require(PerformanceGroupStarterPreset.dualPhoneSticks.makeProfile())
    #expect(profile.groups.count == 1 && profile.layeredInputs.isEmpty)
    let session=try PerformanceGroupGamepadSession(profile:profile,allowRemote:true)
    let left=try #require(session.remoteCapabilities(.phone))
    let right=try #require(session.remoteCapabilities(.phone2))
    #expect(left.drums == 50 && right.drums == 204 && left.drums & right.drums == 0)
    #expect(profile.groups[0].patch.routes.allSatisfy { $0.destination.channel == 9 && $0.destination.kind == .note })
}
