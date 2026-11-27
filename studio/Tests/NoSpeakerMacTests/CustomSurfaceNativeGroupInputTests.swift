#if os(macOS)
import Foundation
import Testing
import NoSpeakerCore
@testable import NoSpeakerMac

private func groupNativeFrame(_ n: Int, surface: TouchSurfaceKind, valid: Bool = true) -> SurfaceTouchFrame {
    .init(surface: surface, contacts: [], timestamp: 0, frameNumber: n,
          acquisitionNS: Int64(n), validNativeEnvelope: valid, rawNativeContactCount: 0)
}
@Test func customNativeGroupInputMergesOriginalReceiptTimesAndKeepsIndependentSequences() throws {
    let group = try #require(CustomSurfaceNativeGroupInput(surfaces: [.trackpad,.magicMouse], orientation:.horizontal, notBefore:0))
    let trackpad = try #require(group.inboxes.first { $0.surface == .trackpad })
    let mouse = try #require(group.inboxes.first { $0.surface == .magicMouse })
    #expect(group.admitsSetup && !group.admitsDelivery)
    trackpad.submit(groupNativeFrame(1,surface:.trackpad))
    #expect(group.begin(at:2))
    #expect(!group.begin(at:3))
    trackpad.submit(groupNativeFrame(4,surface:.trackpad))
    trackpad.submit(groupNativeFrame(6,surface:.trackpad))
    mouse.submit(groupNativeFrame(3,surface:.magicMouse))
    mouse.submit(groupNativeFrame(4,surface:.magicMouse))
    var seen:[CustomSurfaceNativeFrame]=[]
    #expect(group.drain { seen.append($0); return true } == .delivered(4))
    #expect(seen.map(\.observedAt) == [3,4,4,6])
    #expect(seen.map(\.surface) == [.magicMouse,.trackpad,.magicMouse,.trackpad])
}
@Test func customNativeGroupInputFaultRevokesBothAlreadyDrainedBatches() throws {
    let group = try #require(CustomSurfaceNativeGroupInput(surfaces:[.trackpad,.magicMouse],orientation:.horizontal,notBefore:0))
    let trackpad=try #require(group.inboxes.first { $0.surface == .trackpad })
    let mouse=try #require(group.inboxes.first { $0.surface == .magicMouse })
    #expect(group.begin(at:1))
    trackpad.submit(groupNativeFrame(2,surface:.trackpad))
    mouse.submit(groupNativeFrame(3,surface:.magicMouse))
    var seen:[CustomSurfaceNativeFrame]=[]
    #expect(group.drain { frame in
        seen.append(frame)
        mouse.submit(groupNativeFrame(4,surface:.magicMouse,valid:false))
        return true
    } == .revoked)
    #expect(seen.count == 1 && !group.admitsDelivery && !group.admitsSetup)
    #expect(!trackpad.admitsDelivery && !mouse.admitsDelivery)
}
@Test func customNativeGroupInputFailedBeginClosesEveryMember() throws {
    let group=try #require(CustomSurfaceNativeGroupInput(surfaces:[.trackpad,.magicMouse],orientation:.horizontal,notBefore:0))
    let mouse=try #require(group.inboxes.first { $0.surface == .magicMouse })
    mouse.submit(groupNativeFrame(1,surface:.magicMouse,valid:false))
    #expect(!group.begin(at:2))
    #expect(group.inboxes.allSatisfy { !$0.admitsDelivery })
    #expect(!group.begin(at:3))
}
#endif

#if os(macOS)
@Test func customNativeGroupInputRevokedBeforeDrainClosesHealthyPeer() throws {
    let group=try #require(CustomSurfaceNativeGroupInput(surfaces:[.trackpad,.magicMouse],orientation:.horizontal,notBefore:0))
    let mouse=try #require(group.inboxes.first { $0.surface == .magicMouse })
    #expect(group.begin(at:1))
    mouse.submit(groupNativeFrame(2,surface:.magicMouse,valid:false))
    #expect(group.drain { _ in Issue.record("Unexpected delivery"); return true } == .revoked)
    #expect(group.inboxes.allSatisfy { !$0.admitsDelivery })
}
#endif

#if os(macOS)
@Test func customNativeGroupRegistrationBindingIsDistinctAndImmutable() throws {
    let group=try #require(CustomSurfaceNativeGroupInput(surfaces:[.trackpad,.magicMouse],orientation:.horizontal,notBefore:0))
    let a=UUID(), b=UUID()
    #expect(group.bindRegistrations([.trackpad:a,.magicMouse:b]))
    #expect(group.matchesRegistrations([.trackpad:a,.magicMouse:b]))
    #expect(!group.matchesRegistrations([.trackpad:a,.magicMouse:UUID()]))
    #expect(!group.matchesRegistrations([.trackpad:a]))
    #expect(!group.bindRegistrations([.trackpad:b,.magicMouse:a]))
    #expect(group.begin(at:1))
    let mouse=try #require(group.inboxes.first { $0.surface == .magicMouse })
    mouse.submit(.init(surface:.magicMouse,contacts:[],timestamp:0,frameNumber:2,acquisitionNS:2,
        validNativeEnvelope:true,rawNativeContactCount:0,nativeRegistration:a))
    #expect(group.drain { _ in Issue.record("Unexpected delivery");return true } == .revoked)
}
@Test func customNativeGroupMissingOrDuplicateRegistrationClosesBoth() throws {
    let token=UUID()
    for current in [[TouchSurfaceKind.trackpad:token],[.trackpad:token,.magicMouse:token]] {
        let group=try #require(CustomSurfaceNativeGroupInput(surfaces:[.trackpad,.magicMouse],orientation:.horizontal,notBefore:0))
        #expect(!group.bindRegistrations(current))
        #expect(!group.admitsSetup && !group.begin(at:1))
    }
}
#endif
