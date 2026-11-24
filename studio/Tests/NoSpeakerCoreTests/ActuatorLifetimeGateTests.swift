import Foundation
import Dispatch
import Testing
@testable import NoSpeakerCore

@Test func actuatorRetirementIsTerminalAndIdempotent() throws {
    let gate = ActuatorLifetimeGate()
    var writes = 0
    var closes = 0
    try gate.withActive { writes += 1 }
    gate.retire { closes += 1 }
    gate.retire { closes += 1 }
    #expect(throws: ActuatorLifetimeError.retired) {
        try gate.withActive { writes += 1 }
    }
    #expect(writes == 1)
    #expect(closes == 1)
    let newGate = ActuatorLifetimeGate()
    try newGate.withActive { writes += 1 }
    #expect(writes == 2)
}

@Test func retirementDrainsInFlightMockActuationAndRejectsLateWork() throws {
    let gate = ActuatorLifetimeGate()
    let entered = DispatchSemaphore(value: 0)
    let permitReturn = DispatchSemaphore(value: 0)
    let retired = DispatchSemaphore(value: 0)
    let attempting = DispatchSemaphore(value: 0)
    let permitted = DispatchSemaphore(value: 0)
    defer { permitReturn.signal() }
    let workerDone = DispatchSemaphore(value: 0)
    Thread.detachNewThread {
        try? gate.withActive {
            entered.signal()
            if permitReturn.wait(timeout: .now() + 15) == .success {
            permitted.signal()
        }
        }
        workerDone.signal()
    }
    try #require(entered.wait(timeout: .now() + 5) == .success)
    Thread.detachNewThread {
        attempting.signal()
        gate.retire {}
        retired.signal()
    }
    // The active operation deliberately has not returned.
    try #require(attempting.wait(timeout: .now() + 5) == .success)
    #expect(retired.wait(timeout: .now() + .milliseconds(50)) == .timedOut)
    permitReturn.signal()
    try #require(permitted.wait(timeout: .now() + 5) == .success)
    try #require(workerDone.wait(timeout: .now() + 5) == .success)
    try #require(retired.wait(timeout: .now() + 5) == .success)
    #expect(throws: ActuatorLifetimeError.retired) {
        try gate.withActive {}
    }
}
