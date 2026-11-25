import Testing
@testable import NoSpeakerCore

@Test func dawSurfaceChannelsRejectInvalidOrSharedChannels() throws {
    #expect(DAWSurfaceChannels(trackpad:0,magicMouse:0) == nil)
    #expect(DAWSurfaceChannels(trackpad:-1,magicMouse:2) == nil)
    #expect(DAWSurfaceChannels(trackpad:0,magicMouse:16) == nil)
    let split = try #require(DAWSurfaceChannels(trackpad:0,magicMouse:2))
    #expect(split.all == Set([0,2]))
    #expect(split.trackpad == 0 && split.magicMouse == 2)
}

@Test func dawOverviewDistinguishesIndependentNotesFromSharedHelpers() throws {
    let patch = InstrumentPatch(routes:[
        .init(id:"flute",source:.trackpad,signal:.contact,destination:.init(.note,channel:0,number:72)),
        .init(id:"organ",source:.magicMouse,signal:.contact,destination:.init(.note,channel:2,number:60)),
        .init(id:"kick",source:.gamepad1,signal:.padA,destination:.init(.note,channel:9,number:36)),
        .init(id:"pedal",source:.gamepad2,signal:.padRT,destination:.init(.sustain,channel:0))
    ])
    #expect(patch.isValid)
    let rows = DAWRoutingOverview.rows(for:patch)
    #expect(rows.map(\.channel) == [0,2,9])
    let first = try #require(rows.first)
    #expect(first.noteSources == [.trackpad])
    #expect(first.controlSources == [.gamepad2])
    #expect(!first.sharesNotes)
    var shared = patch
    shared.routes[1].destination.channel = 0
    let merged = try #require(DAWRoutingOverview.rows(for:shared).first)
    #expect(merged.sharesNotes)
    #expect(Set(merged.noteSources) == Set([.trackpad,.magicMouse]))
}
