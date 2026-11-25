import Foundation
import Testing
@testable import NoSpeakerCore

@Test func dynamicPreviewListsPossibleChannelsNotFixedAssignments() throws {
    let spec = try DynamicMPEPreview.specification(name:"Wide",degrees:"0, 220, 400, 500, 700, 900, 1100",rootText:"60")
    let group = PerformanceInstrumentGroup(name:"Wide",patch:.init(routes:[
        .init(id:"a",source:.gamepad1,signal:.padA,destination:.init(.note,channel:3,number:62)),
        .init(id:"b",source:.gamepad1,signal:.padB,destination:.init(.note,channel:3,number:74)),
        .init(id:"c",source:.gamepad1,signal:.padX,destination:.init(.note,channel:3,number:64)),
        .init(id:"pedal",source:.gamepad1,signal:.padRT,destination:.init(.sustain,channel:3))
    ]))
    let profile = PerformanceGroupProfile(groups:[group])
    let preview = try DynamicMPEPreview(profile:profile,tuning:[group.id:spec])
    let g = try #require(preview.groups.first)
    #expect(g.port == group.plannedPortName && g.plan.mappedNoteCount == 3)
    #expect(g.routes[0].possibleChannels == g.routes[1].possibleChannels)
    #expect(Set(g.routes[0].possibleChannels).isDisjoint(with:g.routes[2].possibleChannels))
    #expect(g.routes[3].possibleChannels == [1])
    #expect(Set(g.routes[0].possibleChannels+g.routes[2].possibleChannels) == Set(2...16))
    #expect(g.plan.possibleChannels(for:.init(.note,channel:4,number:62)).isEmpty)
    #expect(throws:MIDIClipError.invalidClip) { try DynamicMPEPreview(profile:profile,tuning:[:]) }
    #expect(throws:MIDIClipError.invalidNote) { try DynamicMPEPreview.specification(name:"Bad",degrees:"0, 220, 400",rootText:"128") }
}
