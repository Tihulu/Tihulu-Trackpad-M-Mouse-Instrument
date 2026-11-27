import Foundation
import Testing
@testable import NoSpeakerCore

private func groupMember(_ surface: CustomSurfacePadLayout.Surface) throws -> CustomSurfacePerformanceGroup.Member {
    let layout = try #require(CustomSurfacePadLayout(surface: surface, pads: [
        .init(id: "note", label: "Note", x: 0, y: 0, width: 10000, height: 10000, assignment: .note(60))
    ]))
    return .init(plan: try .init(layout: layout, melodicChannel: 2), permitsNeutralSilence: true)
}
private let groupContact = CustomSurfaceContactProjection.Contact(id: 1, x: 0.5, y: 0.5)

@Test func customSurfaceGroupIndependentSourcesAndGenerationFence() throws {
    var next: UInt32 = 1
    var now: Int64 = 0
    var wire: [UInt32: [[UInt8]]] = [:]
    let host = CustomSurfaceEndpointHost(backend: .init(create: { name in
        defer { next += 1 }
        return .init(endpoint: .init(handle: next, uniqueID: Int32(next), name: name), succeeded: true)
    }, owns: { _ in true }, send: { e,b in wire[e.handle,default:[]].append(b); return true }, dispose: { _ in true }))
    let group = CustomSurfacePerformanceGroup(host: host)
    let members = try [groupMember(.trackpad), groupMember(.magicMouse)]
    #expect(group.start([members[0],members[0]],clock:{now},admitsLive:{true}) == .refused)
    #expect(next == 1)
    guard case .started(let run) = group.start(members,clock:{now},admitsLive:{true}) else {
        Issue.record("Group did not start"); return
    }
    group.frame(run:run,surface:.trackpad,contacts:[],sequence:1,observedAt:0)
    group.frame(run:run,surface:.magicMouse,contacts:[],sequence:1,observedAt:0)
    now=1
    group.frame(run:run,surface:.trackpad,contacts:[groupContact],sequence:2,observedAt:now)
    group.frame(run:run,surface:.magicMouse,contacts:[groupContact],sequence:2,observedAt:now)
    now=2
    #expect(group.frame(run:UUID(),surface:.trackpad,contacts:[],sequence:3,observedAt:now) == nil)
    #expect(group.frame(run:run,surface:.phone,contacts:[],sequence:3,observedAt:now) == nil)
    group.frame(run:run,surface:.trackpad,contacts:[],sequence:3,observedAt:now)
    #expect(wire[1] == [[0x92,60,100],[0x82,60,0]])
    #expect(wire[2] == [[0x92,60,100]])
    group.stop()
    #expect(wire[2] == [[0x92,60,100],[0x82,60,0]])
    #expect(group.phase == .idle && host.statuses.isEmpty)
}

@Test func customSurfaceGroupPartialCreationRollsBackAndBlocksRecovery() throws {
    var created = 0
    var disposals = 0
    var failDisposal = true
    let host = CustomSurfaceEndpointHost(backend:.init(create:{ name in
        created += 1
        guard created == 1 else { return nil }
        return .init(endpoint:.init(handle:1,uniqueID:1,name:name),succeeded:true)
    },owns:{_ in true},send:{_,_ in Issue.record("Unexpected MIDI");return false},
       dispose:{_ in disposals += 1;return !failDisposal}))
    let group=CustomSurfacePerformanceGroup(host:host)
    let members=try [groupMember(.trackpad),groupMember(.magicMouse)]
    #expect(group.start(members,clock:{0},admitsLive:{true}) == .recoveryPending)
    #expect(group.runID == nil && group.phase == .recoveryPending && disposals == 1)
    group.stop()
    #expect(disposals == 1)
    #expect(group.start(members,clock:{0},admitsLive:{true}) == .refused)
    failDisposal=false
    group.retryRecovery()
    #expect(disposals == 2 && group.phase == .idle && host.statuses.isEmpty)
}
