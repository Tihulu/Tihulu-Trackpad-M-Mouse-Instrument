import Testing
@testable import NoSpeakerCore

@Test func quickStartProfilesUseOnlySupportedBoundedRoutes() throws {
    for preset in MusicianQuickStart.allCases {
        let patch = try #require(preset.patch())
        #expect(patch.isValid)
        #expect(!patch.routes.isEmpty)
        #expect(patch.routes.count <= SensorRouter.maxMappings)
        #expect(PhysicalPatchRuntime.supports(patch, allowRemote: true))
    }
}

@Test func simpleQuickStartsDoNotRequireUnrelatedDevices() throws {
    let phone = try #require(MusicianQuickStart.phoneDrums.patch())
    #expect(Set(phone.routes.map(\.source)) == [.phone])
    #expect(Set(phone.routes.map { $0.destination.channel }) == [9])
    let lead = try #require(MusicianQuickStart.controllerLead.patch())
    #expect(Set(lead.routes.map(\.source)) == [.gamepad1])
    #expect(Set(lead.routes.map { $0.destination.channel }) == [3])
    let helper = try #require(MusicianQuickStart.controllerHelper.patch())
    #expect(Set(helper.routes.map(\.source)) == [.gamepad1])
    #expect(Set(helper.routes.map { $0.destination.channel }) == [0])
    #expect(!helper.routes.contains { $0.destination.kind == .note })
    #expect(!helper.routes.contains {
        $0.destination.kind == .controlChange && [7, 11].contains($0.destination.number)
    })
    #expect(helper.routes.contains { $0.destination.kind == .sustain })
}

@Test func quickStartDuosKeepSeparateSourcesAndChannels() throws {
    let controllers = try #require(MusicianQuickStart.controllerDuo.patch())
    #expect(Set(controllers.routes.map(\.source)) == [.gamepad1, .gamepad2])
    #expect(Set(controllers.routes.filter { $0.source == .gamepad1 }.map { $0.destination.channel }) == [3])
    #expect(Set(controllers.routes.filter { $0.source == .gamepad2 }.map { $0.destination.channel }) == [9])
    let mobile = try #require(MusicianQuickStart.mobileDuo.patch())
    #expect(Set(mobile.routes.map(\.source)) == [.phone, .tablet])
    #expect(Set(mobile.routes.filter { $0.source == .phone }.map { $0.destination.channel }) == [9])
    #expect(Set(mobile.routes.filter { $0.source == .tablet }.map { $0.destination.channel }) == [1])
    #expect(MusicianQuickStart.fullParty.patch() == PartyJamPreset.patch())
}
