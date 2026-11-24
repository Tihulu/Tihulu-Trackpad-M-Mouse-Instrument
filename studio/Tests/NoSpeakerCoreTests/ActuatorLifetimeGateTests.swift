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

@Test func retirementDrainsInFlightMockActuationAndRejectsLateWork() {
    let gate = ActuatorLifetimeGate()
    let entered = DispatchSemaphore(value: 0)
    let permitReturn = DispatchSemaphore(value: 0)
    let retired = DispatchSemaphore(value: 0)
    let workerDone = DispatchSemaphore(value: 0)
    DispatchQueue.global().async {
        try? gate.withActive {
            entered.signal()
            _ = permitReturn.wait(timeout: .now() + 3)
        }
        workerDone.signal()
    }
    let started = entered.wait(timeout: .now() + 2)
    #expect(started == .success)
    DispatchQueue.global().async {
        gate.retire {}
        retired.signal()
    }
    // The active operation deliberately has not returned.
    #expect(retired.wait(timeout: .now() + .milliseconds(30)) == .timedOut)
    permitReturn.signal()
    #expect(workerDone.wait(timeout: .now() + 2) == .success)
    #expect(retired.wait(timeout: .now() + 2) == .success)
    #expect(throws: ActuatorLifetimeError.retired) {
        try gate.withActive {}
    }
}
