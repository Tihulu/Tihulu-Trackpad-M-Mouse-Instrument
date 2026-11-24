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

@Test func sourceFenceStopWaitsForInFlightSubmission() {
    let fence = HapticSourceFence()
    let token = fence.begin()
    let entered = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    let done = DispatchSemaphore(value: 0)
    let stopped = DispatchSemaphore(value: 0)
    DispatchQueue.global().async {
        fence.submit(token) {
            entered.signal()
            _ = release.wait(timeout: .now() + 3)
        }
        done.signal()
    }
    #expect(entered.wait(timeout: .now() + 2) == .success)
    DispatchQueue.global().async {
        fence.revoke()
        stopped.signal()
    }
    #expect(stopped.wait(timeout: .now() + .milliseconds(30)) == .timedOut)
    release.signal()
    #expect(done.wait(timeout: .now() + 2) == .success)
    #expect(stopped.wait(timeout: .now() + 2) == .success)
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
