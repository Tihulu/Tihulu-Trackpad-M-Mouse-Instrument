import Testing
@testable import NoSpeakerCore

private final class LifetimeProbe {
    var retired = 0
    var finished = 0
    var clean = false
}

@MainActor
@Test func relativeHostLifetimeInvalidatesBeforeCloseAndRetainsDirtyOwner() throws {
    let slot = NativeHelperRelativeHostLifetime<LifetimeProbe>()
    let old = LifetimeProbe(), replacement = LifetimeProbe()
    let token = try #require(slot.install(old))
    #expect(slot.phase == .active)
    #expect(slot.activeHost(for: token) === old)
    #expect(slot.install(replacement) == nil)
    let closedClean = slot.close(token, retire: { host in
        #expect(host === old)
        #expect(slot.phase == .closing)
        #expect(slot.activeHost(for: token) == nil)
        host.retired += 1
    }, finish: { host in
        #expect(host.retired == 1)
        host.finished += 1
        return host.clean
    })
    #expect(!closedClean)
    #expect(slot.phase == .closing)
    #expect(slot.install(replacement) == nil)
    #expect(!slot.retry(token, finish: { host in host.finished += 1; return false }))
    #expect(old.retired == 1 && old.finished == 2)
    old.clean = true
    #expect(slot.retry(token, finish: { host in host.finished += 1; return host.clean }))
    #expect(slot.phase == .idle && old.retired == 1 && old.finished == 3)
    let fresh = try #require(slot.install(replacement))
    #expect(fresh != token)
    #expect(slot.activeHost(for: fresh) === replacement)
    #expect(slot.activeHost(for: token) == nil)
    #expect(!slot.close(token, retire: { $0.retired += 1 }, finish: { _ in true }))
    #expect(!slot.retry(token, finish: { $0.finished += 1; return true }))
    #expect(replacement.retired == 0 && replacement.finished == 0)
}

@MainActor
@Test func relativeHostLifetimeRejectsReentrantAndForeignDisposal() throws {
    let slot = NativeHelperRelativeHostLifetime<LifetimeProbe>()
    let other = NativeHelperRelativeHostLifetime<LifetimeProbe>()
    let host = LifetimeProbe(), foreign = LifetimeProbe()
    let token = try #require(slot.install(host))
    let foreignToken = try #require(other.install(foreign))
    #expect(!slot.close(foreignToken, retire: { $0.retired += 1 }, finish: { _ in true }))
    #expect(!slot.retry(token, finish: { $0.finished += 1; return true }))
    let closedClean = slot.close(token, retire: { current in
        current.retired += 1
        #expect(!slot.close(token, retire: { $0.retired += 1 }, finish: { _ in true }))
        #expect(!slot.retry(token, finish: { $0.finished += 1; return true }))
        #expect(slot.install(foreign) == nil)
    }, finish: { current in
        current.finished += 1
        #expect(!slot.retry(token, finish: { $0.finished += 1; return true }))
        #expect(!slot.close(token, retire: { $0.retired += 1 }, finish: { _ in true }))
        #expect(slot.install(foreign) == nil)
        return true
    })
    #expect(closedClean)
    #expect(slot.phase == .idle)
    #expect(host.retired == 1 && host.finished == 1)
    #expect(other.activeHost(for: foreignToken) === foreign)
    #expect(foreign.retired == 0 && foreign.finished == 0)
}

@MainActor
@Test func relativeHostLifetimeRepeatedHandoffsKeepOldCallbacksInert() throws {
    let slot = NativeHelperRelativeHostLifetime<LifetimeProbe>()
    var old: [NativeHelperRelativeHostLifetime<LifetimeProbe>.Token] = []
    for cycle in 0..<64 {
        let host = LifetimeProbe()
        let token = try #require(slot.install(host))
        for stale in old {
            #expect(slot.activeHost(for: stale) == nil)
            #expect(!slot.close(stale, retire: { $0.retired += 1 }, finish: { _ in true }))
            #expect(!slot.retry(stale, finish: { $0.finished += 1; return true }))
        }
        #expect(host.retired == 0 && host.finished == 0)
        #expect(slot.close(token, retire: { $0.retired += 1 }, finish: { $0.finished += 1; return cycle % 2 == 0 }) == (cycle % 2 == 0))
        if cycle % 2 != 0 {
            #expect(slot.install(LifetimeProbe()) == nil)
            #expect(slot.retry(token, finish: { $0.finished += 1; return true }))
        }
        #expect(host.retired == 1 && host.finished == (cycle % 2 == 0 ? 1 : 2))
        old.append(token)
    }
    #expect(slot.phase == .idle)
}
