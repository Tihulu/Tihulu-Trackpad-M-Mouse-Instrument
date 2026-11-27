import Foundation
import Testing
@testable import NoSpeakerCore

private func hostPlan() throws -> CustomSurfaceMixedPlan {
    let layout = try #require(CustomSurfacePadLayout(surface: .trackpad, pads: [
        .init(id: "note", label: "Note", x: 0, y: 0, width: 10000, height: 10000, assignment: .note(60))
    ]))
    return try .init(layout: layout, melodicChannel: 2)
}
private let hostContact = CustomSurfaceContactProjection.Contact(id: 1, x: 0.5, y: 0.5)

@Test func customSurfaceHostRetainsCleanupAndDisposalDebt() throws {
    var now: Int64 = 0
    var failOff = true, failDispose = true
    var wire: [[UInt8]] = []
    var disposals = 0
    let host = CustomSurfaceEndpointHost(backend: .init(create: { name in
        .init(endpoint: .init(handle: 12, uniqueID: 42, name: name), succeeded: true)
    }, owns: { _ in true }, send: { _, bytes in
        wire.append(bytes)
        return !failOff || bytes[0] != 0x82
    }, dispose: { _ in disposals += 1; return !failDispose }))
    let opened = try #require(host.open(plan: try hostPlan(), clock: { now }, admitsLive: { true }))
    #expect(opened.phase == .live)
    _ = host.frame(opened.id, surface: .trackpad, contacts: [], sequence: 1, observedAt: 0)
    now = 1
    _ = host.frame(opened.id, surface: .trackpad, contacts: [hostContact], sequence: 2, observedAt: 1)
    #expect(host.close(opened.id)?.phase == .cleanupPending)
    #expect(disposals == 0)
    failOff = false
    #expect(host.close(opened.id)?.phase == .disposalPending)
    #expect(disposals == 1)
    #expect(wire == [[0x92,60,100],[0x82,60,0],[0x82,60,0]])
    failDispose = false
    #expect(host.close(opened.id)?.phase == .closed)
    #expect(disposals == 2)
    #expect(wire.count == 3)
    #expect(host.statuses.isEmpty)
    #expect(host.close(opened.id) == nil)
}

@Test func customSurfaceHostQuarantinesLostIdentityPermanently() throws {
    var now: Int64 = 0
    var owned = true
    var wire: [[UInt8]] = []
    var disposals = 0
    let host = CustomSurfaceEndpointHost(backend: .init(create: { name in
        .init(endpoint: .init(handle: 12, uniqueID: 42, name: name), succeeded: true)
    }, owns: { _ in owned }, send: { _, bytes in wire.append(bytes); return true },
       dispose: { _ in disposals += 1; return true }))
    let opened = try #require(host.open(plan: try hostPlan(), clock: { now }, admitsLive: { true }))
    _ = host.frame(opened.id, surface: .trackpad, contacts: [], sequence: 1, observedAt: 0)
    now = 1
    _ = host.frame(opened.id, surface: .trackpad, contacts: [hostContact], sequence: 2, observedAt: 1)
    owned = false
    host.poll()
    #expect(host.statuses.first?.phase == .identityLost)
    #expect(host.statuses.first?.outstanding == Set([SensorDestination(.note, channel: 2, number: 60)]))
    owned = true
    #expect(host.close(opened.id)?.phase == .identityLost)
    #expect(disposals == 0)
    #expect(wire.count == 1)
}

@Test func customSurfaceHostKeepsPartialCreationAndBoundsCapacity() throws {
    var creations = 0, disposals = 0, sends = 0
    let host = CustomSurfaceEndpointHost(backend: .init(create: { name in
        creations += 1
        return .init(endpoint: .init(handle: UInt32(creations), uniqueID: 0, name: name), succeeded: false)
    }, owns: { _ in true }, send: { _, _ in sends += 1; return true },
       dispose: { _ in disposals += 1; return true }))
    let plan = try hostPlan()
    for _ in 0..<CustomSurfaceEndpointHost.capacity {
        let status = try #require(host.open(plan: plan, clock: { 0 }, admitsLive: { true }))
        #expect(status.phase == .identityLost)
        #expect(host.close(status.id)?.phase == .identityLost)
    }
    #expect(host.open(plan: plan, clock: { 0 }, admitsLive: { true }) == nil)
    #expect(creations == CustomSurfaceEndpointHost.capacity)
    #expect(disposals == 0 && sends == 0)
}

@Test func customSurfaceHostWatchdogRetiresAndExplicitCloseDisposes() throws {
    var now: Int64 = 0
    var wire: [[UInt8]] = []
    var disposals = 0
    let host = CustomSurfaceEndpointHost(backend: .init(create: { name in
        .init(endpoint: .init(handle: 12, uniqueID: 42, name: name), succeeded: true)
    }, owns: { _ in true }, send: { _, bytes in wire.append(bytes); return true },
       dispose: { _ in disposals += 1; return true }))
    let opened = try #require(host.open(plan: try hostPlan(), clock: { now }, admitsLive: { true }))
    _ = host.frame(opened.id, surface: .trackpad, contacts: [], sequence: 1, observedAt: 0)
    now = 1
    _ = host.frame(opened.id, surface: .trackpad, contacts: [hostContact], sequence: 2, observedAt: 1)
    now = 150_000_001
    host.poll()
    #expect(host.statuses.first?.phase == .retired)
    #expect(wire == [[0x92,60,100],[0x82,60,0]])
    #expect(disposals == 0)
    #expect(host.close(opened.id)?.phase == .closed)
    #expect(disposals == 1)
}

@Test func customSurfaceHostRejectsCrossDeviceFramesWithoutRenewingFreshness() throws {
    var now: Int64 = 0
    var wire: [[UInt8]] = []
    let host = CustomSurfaceEndpointHost(backend: .init(create: { name in
        .init(endpoint: .init(handle: 12, uniqueID: 42, name: name), succeeded: true)
    }, owns: { _ in true }, send: { _, bytes in wire.append(bytes); return true },
       dispose: { _ in true }))
    let opened = try #require(host.open(plan: try hostPlan(), clock: { now }, admitsLive: { true }))
    #expect(opened.surface == .trackpad)
    #expect(host.frame(opened.id, surface: .magicMouse, contacts: [], sequence: 1, observedAt: 0) == nil)
    now = 1
    _ = host.frame(opened.id, surface: .trackpad, contacts: [hostContact], sequence: 1, observedAt: 1)
    #expect(wire.isEmpty)
    now = 2
    _ = host.frame(opened.id, surface: .trackpad, contacts: [], sequence: 2, observedAt: 2)
    now = 3
    _ = host.frame(opened.id, surface: .trackpad, contacts: [hostContact], sequence: 3, observedAt: 3)
    #expect(wire == [[0x92,60,100]])
    now = 100_000_000
    #expect(host.frame(opened.id, surface: .phone, contacts: [], sequence: 100, observedAt: now) == nil)
    #expect(host.frame(UUID(), surface: .trackpad, contacts: [], sequence: 100, observedAt: now) == nil)
    #expect(wire.count == 1)
    now = 150_000_003
    host.poll()
    #expect(host.statuses.first?.phase == .retired)
    #expect(wire == [[0x92,60,100],[0x82,60,0]])
}

@Test func customSurfaceHostReportsActualNeutralHandshakeNotJustOpenPort() throws {
    var now: Int64 = 0
    var wire: [[UInt8]] = []
    let host = CustomSurfaceEndpointHost(backend: .init(create: { name in
        .init(endpoint: .init(handle: 12, uniqueID: 42, name: name), succeeded: true)
    }, owns: { _ in true }, send: { _, bytes in wire.append(bytes); return true },
       dispose: { _ in true }))
    let opened = try #require(host.open(plan: try hostPlan(), permitsNeutralSilence: true,
                                        clock: { now }, admitsLive: { true }))
    #expect(!opened.hasNeutralHandshake)
    let occupied = try #require(host.frame(opened.id, surface: .trackpad, contacts: [hostContact], sequence: 1, observedAt: 0))
    #expect(!occupied.hasNeutralHandshake && wire.isEmpty)
    now = 1
    let neutral = try #require(host.frame(opened.id, surface: .trackpad, contacts: [], sequence: 2, observedAt: 1))
    #expect(neutral.hasNeutralHandshake && wire.isEmpty)
    now = 2
    let playing = try #require(host.frame(opened.id, surface: .trackpad, contacts: [hostContact], sequence: 3, observedAt: 2))
    #expect(playing.hasNeutralHandshake && wire.count == 1)
    #expect(host.close(opened.id)?.hasNeutralHandshake == false)
}

@Test func customSurfaceHostAutomaticStopDoesNotRetryFailedCleanup() throws {
    var now: Int64 = 0
    var allowed = true
    var failOff = true
    var wire: [[UInt8]] = []
    var disposals = 0
    let host = CustomSurfaceEndpointHost(backend: .init(create: { name in
        .init(endpoint: .init(handle: 12, uniqueID: 42, name: name), succeeded: true)
    }, owns: { _ in true }, send: { _, bytes in
        wire.append(bytes)
        return !failOff || bytes[0] != 0x82
    }, dispose: { _ in disposals += 1; return true }))
    let opened = try #require(host.open(plan: try hostPlan(), clock: { now }, admitsLive: { allowed }))
    _ = host.frame(opened.id, surface: .trackpad, contacts: [], sequence: 1, observedAt: 0)
    now = 1
    _ = host.frame(opened.id, surface: .trackpad, contacts: [hostContact], sequence: 2, observedAt: 1)
    allowed = false
    host.poll()
    #expect(host.statuses.first?.phase == .cleanupPending)
    #expect(wire.count == 2)
    failOff = false
    #expect(host.close(opened.id, retryPending: false)?.phase == .cleanupPending)
    #expect(wire.count == 2 && disposals == 0)
    #expect(host.close(opened.id)?.phase == .closed)
    #expect(wire.count == 3 && disposals == 1)
}

@Test func customSurfaceHostQuarantinesBothIncarnationsOnDuplicateEndpoint() throws {
    var now: Int64 = 0
    var wire: [[UInt8]] = []
    var disposals = 0
    let host = CustomSurfaceEndpointHost(backend: .init(create: { name in
        .init(endpoint: .init(handle: 12, uniqueID: 42, name: name), succeeded: true)
    }, owns: { _ in true }, send: { _, bytes in wire.append(bytes); return true },
       dispose: { _ in disposals += 1; return true }))
    let plan = try hostPlan()
    let first = try #require(host.open(plan: plan, clock: { now }, admitsLive: { true }))
    _ = host.frame(first.id, surface: .trackpad, contacts: [], sequence: 1, observedAt: 0)
    now = 1
    _ = host.frame(first.id, surface: .trackpad, contacts: [hostContact], sequence: 2, observedAt: 1)
    let second = try #require(host.open(plan: plan, clock: { now }, admitsLive: { true }))
    #expect(second.phase == .identityLost)
    #expect(host.statuses.allSatisfy { $0.phase == .identityLost })
    #expect(host.statuses.first(where: { $0.id == first.id })?.outstanding == Set([SensorDestination(.note, channel: 2, number: 60)]))
    now = 2
    _ = host.frame(first.id, surface: .trackpad, contacts: [], sequence: 3, observedAt: now)
    host.poll()
    #expect(host.close(first.id)?.phase == .identityLost)
    #expect(host.close(second.id)?.phase == .identityLost)
    #expect(wire == [[0x92,60,100]] && disposals == 0)
}

@Test func customSurfaceHostMeasuresLocalIdentityAndSendSeparately() throws {
    var now: Int64 = 0
    var measured: UInt64 = 0
    var failOff = false
    let host = CustomSurfaceEndpointHost(backend: .init(create: { name in
        .init(endpoint: .init(handle: 12, uniqueID: 42, name: name), succeeded: true)
    }, owns: { _ in measured += 20_000; return true }, send: { _, bytes in
        measured += 3_000
        return !failOff || bytes[0] != 0x82
    }, dispose: { _ in true }), measure: { measured })
    let opened = try #require(host.open(plan: try hostPlan(), clock: { now }, admitsLive: { true }))
    _ = host.frame(opened.id, surface: .trackpad, contacts: [], sequence: 1, observedAt: 0)
    now = 100
    _ = host.frame(opened.id, surface: .trackpad, contacts: [hostContact], sequence: 2, observedAt: 1)
    failOff = true
    #expect(host.close(opened.id)?.phase == .cleanupPending)
    let evidence = try #require(host.timingEvidence(opened.id))
    #expect(evidence.maximumIdentityNS == 20_000 && evidence.maximumSendNS == 3_000)
    #expect(evidence.maximumFrameAgeNS == 99 && evidence.sendAttempts == 2 && evidence.failedSends == 1)
    #expect(evidence.identityChecks > 0 && evidence.failedIdentityChecks == 0)
}

@Test func customSurfaceHostPreservesOnlyMostRecentClosedTiming() throws {
    var next: UInt32 = 1
    let host = CustomSurfaceEndpointHost(backend: .init(create: { name in
        defer { next += 1 }
        return .init(endpoint: .init(handle: next, uniqueID: Int32(next), name: name), succeeded: true)
    }, owns: { _ in true }, send: { _, _ in true }, dispose: { _ in true }))
    let plan = try hostPlan()
    let first = try #require(host.open(plan: plan, clock: { 0 }, admitsLive: { true }))
    #expect(host.close(first.id)?.phase == .closed)
    #expect(host.timingEvidence(first.id) != nil && host.statuses.isEmpty)
    let second = try #require(host.open(plan: plan, clock: { 0 }, admitsLive: { true }))
    #expect(host.close(second.id)?.phase == .closed)
    #expect(host.timingEvidence(first.id) == nil && host.timingEvidence(second.id) != nil)
}
