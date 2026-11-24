import Foundation
import Dispatch
import Testing
@testable import NoSpeakerCore

@Test func sourceFenceRevocationIsScopedAndOldLeaseCannotReturn() {
    let a = HapticSourceFence()
    let b = HapticSourceFence()
    let old = a.begin()
    let other = b.begin()
    var writes = 0
    #expect(a.submit(old) { writes += 1 })
    a.revoke()
    #expect(!a.submit(old) { writes += 100 })
    #expect(b.submit(other) { writes += 1 })
    let next = a.begin()
    #expect(!a.submit(old) { writes += 100 })
    #expect(a.submit(next) { writes += 1 })
    #expect(writes == 3)
}

@Test func sourceFenceStopWaitsForInFlightSubmission() throws {
    let fence = HapticSourceFence()
    let token = fence.begin()
    let entered = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    let done = DispatchSemaphore(value: 0)
    let stopped = DispatchSemaphore(value: 0)
    let attempting = DispatchSemaphore(value: 0)
    let permitted = DispatchSemaphore(value: 0)
    defer { release.signal() }
    Thread.detachNewThread {
        fence.submit(token) {
            entered.signal()
            if release.wait(timeout: .now() + 15) == .success {
            permitted.signal()
        }
        }
        done.signal()
    }
    try #require(entered.wait(timeout: .now() + 5) == .success)
    Thread.detachNewThread {
        attempting.signal()
        fence.revoke()
        stopped.signal()
    }
    try #require(attempting.wait(timeout: .now() + 5) == .success)
    #expect(stopped.wait(timeout: .now() + .milliseconds(50)) == .timedOut)
    release.signal()
    try #require(permitted.wait(timeout: .now() + 5) == .success)
    try #require(done.wait(timeout: .now() + 5) == .success)
    try #require(stopped.wait(timeout: .now() + 5) == .success)
    #expect(!fence.submit(token) {})
}

@Test func beginningNewSourceLeaseRejectsQueuedOldWork() {
    let fence = HapticSourceFence()
    let old = fence.begin()
    let next = fence.begin()
    #expect(!fence.submit(old) {})
    #expect(fence.submit(next) {})
    fence.drain()
    #expect(fence.submit(next) {})
}
