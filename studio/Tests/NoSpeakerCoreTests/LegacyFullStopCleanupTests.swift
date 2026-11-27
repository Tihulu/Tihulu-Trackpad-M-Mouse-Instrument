import Testing
@testable import NoSpeakerCore

struct LegacyFullStopCleanupTests {
    private typealias Message = LegacyGateReleaseDebt.Message

    @MainActor private final class Service {
        var gates = LegacyGateReleaseDebt()
        var controllers = LegacyControllerReleaseDebt()
        var attempted: [Int] = []
        var rangeCompletions = 0

        init(channel: Int) {
            gates.record(.init(0x90 | channel, 60, 90), succeeded: true)
            gates.record(.init(0xb0 | channel, 64, 127), succeeded: true)
            controllers.record(.init(0xe0 | channel, 1, 65), neutral: 8192, succeeded: true)
            controllers.record(.init(0xb0 | channel, 74, 90), neutral: 0, succeeded: true)
            controllers.beginRange(channel: channel)
        }

        var pending: Bool { !gates.isEmpty || !controllers.isEmpty }
        func finish() -> Bool {
            NativeHelperRelativeHostPolicy.permitsEmptyTerminalClosure(reservationsEmpty: true,
                transportReady: false, shutdownCleanupPending: pending, recoveryRequired: false)
        }

        func stop(channel: Int, failureMask: Int) {
            attempted = []
            LegacyRecoveryPolicy.drainAttemptedCleanup(pendingGates: { self.gates.pending },
                pendingRanges: { self.controllers.pendingRanges },
                pendingControllers: { self.controllers.pending },
                send: { message, neutral, rangePart in
                    #expect(message.status & 15 == channel)
                    let bit: Int
                    if rangePart {
                        #expect(message.data2 == 127)
                        #expect(neutral == nil)
                        #expect([100, 101].contains(message.data1))
                        bit = message.data1 == 101 ? 16 : 32
                    } else if LegacyGateReleaseDebt.isGate(message) {
                        #expect(message.data2 == 0)
                        #expect(neutral == nil)
                        bit = message.status & 0xf0 == 0x80 ? 1 : 2
                    } else {
                        let bend = message.status & 0xf0 == 0xe0
                        #expect(neutral == (bend ? 8192 : 0))
                        #expect(message.data1 == (bend ? 0 : 74))
                        #expect(message.data2 == (bend ? 64 : 0))
                        bit = bend ? 4 : 8
                    }
                    self.attempted.append(bit)
                    let succeeded = failureMask & bit == 0
                    self.gates.record(message, succeeded: succeeded)
                    if let neutral { self.controllers.record(message, neutral: neutral, succeeded: succeeded) }
                    return succeeded
                }, completeRange: { channel in
                    self.rangeCompletions += 1
                    self.controllers.completeRange(channel: channel)
                })
        }
    }

    @Test(arguments: Array(0...15)) @MainActor
    func everyWireOutcomeRetainsOnlyOutstandingDebt(channel: Int) throws {
        let order = [2, 1, 16, 32, 8, 4]
        for mask in 0...63 {
            let service = Service(channel: channel)
            let slot = NativeHelperRelativeHostLifetime<Service>()
            let token = try #require(slot.install(service))
            service.stop(channel: channel, failureMask: mask)
            #expect(service.attempted == order)
            #expect(service.pending == (mask != 0))
            #expect(service.rangeCompletions == (mask & 48 == 0 ? 1 : 0))
            let closed = slot.close(token, retire: { _ in }, finish: { $0.finish() })
            #expect(closed == (mask == 0))
            #expect(slot.phase == (mask == 0 ? .idle : .closing))
            let retryMask = mask & 48 == 0 ? mask : mask | 48
            service.stop(channel: channel, failureMask: 0)
            #expect(service.attempted == order.filter { retryMask & $0 != 0 })
            #expect(service.rangeCompletions == 1)
            #expect(!service.pending)
            if mask != 0 {
                let recovered = slot.retry(token, finish: { $0.finish() })
                #expect(recovered)
            }
            #expect(slot.phase == .idle)
            service.stop(channel: channel, failureMask: 63)
            #expect(service.attempted.isEmpty)
            #expect(!service.pending)
        }
    }

    @Test func cleanupReadsControllerSnapshotAfterRangePhase() {
        var trace: [String] = []
        var pending: [Message] = []
        LegacyRecoveryPolicy.drainAttemptedCleanup(pendingGates: { trace.append("gates"); return [] },
            pendingRanges: { trace.append("ranges"); return [2] },
            pendingControllers: { trace.append("controllers"); return pending },
            send: { message, _, _ in trace.append("send-\(message.data1)"); return true },
            completeRange: { _ in trace.append("complete"); pending.append(.init(0xb2, 74, 0)) })
        #expect(trace == ["gates", "ranges", "send-101", "send-100", "complete", "controllers", "send-74"])
    }
}
