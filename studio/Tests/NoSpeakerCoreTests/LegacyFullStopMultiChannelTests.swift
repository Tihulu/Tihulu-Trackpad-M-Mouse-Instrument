import Testing
@testable import NoSpeakerCore

struct LegacyFullStopMultiChannelTests {
    private struct Attempt: Equatable {
        let message: LegacyGateReleaseDebt.Message
        let neutral: Int?
        let range: Bool
        let bit: Int
    }

    private static func expectedOrder() -> [Attempt] {
        let channels = Array(0...15)
        let pedals = channels.map { Attempt(message: .init(0xb0 | $0, 64, 0), neutral: nil, range: false, bit: 2) }
        let notes = channels.map { Attempt(message: .init(0x80 | $0, 60, 0), neutral: nil, range: false, bit: 1) }
        let ranges = channels.flatMap { channel in
            [Attempt(message: .init(0xb0 | channel, 101, 127), neutral: nil, range: true, bit: 16),
             Attempt(message: .init(0xb0 | channel, 100, 127), neutral: nil, range: true, bit: 32)]
        }
        let controls = channels.map { Attempt(message: .init(0xb0 | $0, 74, 0), neutral: 0, range: false, bit: 8) }
        let bends = channels.map { Attempt(message: .init(0xe0 | $0, 0, 64), neutral: 8192, range: false, bit: 4) }
        return pedals + notes + ranges + controls + bends
    }

    @MainActor private final class Service {
        var gates = LegacyGateReleaseDebt()
        var controllers = LegacyControllerReleaseDebt()
        var attempted: [Attempt] = []
        var completedRanges: [Int] = []
        init(reversed: Bool) {
            let channels = reversed ? Array((0...15).reversed()) : Array(0...15)
            for channel in channels {
                gates.record(.init(0x90 | channel, 60, 90), succeeded: true)
                gates.record(.init(0xb0 | channel, 64, 127), succeeded: true)
                controllers.record(.init(0xe0 | channel, 1, 65), neutral: 8192, succeeded: true)
                controllers.record(.init(0xb0 | channel, 74, 90), neutral: 0, succeeded: true)
                controllers.beginRange(channel: channel)
            }
        }
        var pending: Bool { !gates.isEmpty || !controllers.isEmpty }
        func finish() -> Bool {
            NativeHelperRelativeHostPolicy.permitsEmptyTerminalClosure(reservationsEmpty: true,
                transportReady: false, shutdownCleanupPending: pending, recoveryRequired: false)
        }
        func stop(failures: [Int]) {
            attempted = []
            completedRanges = []
            LegacyRecoveryPolicy.drainAttemptedCleanup(pendingGates: { self.gates.pending },
                pendingRanges: { self.controllers.pendingRanges }, pendingControllers: { self.controllers.pending },
                send: { message, neutral, range in
                    let bit: Int
                    if range { bit = message.data1 == 101 ? 16 : 32 }
                    else if LegacyGateReleaseDebt.isGate(message) { bit = message.status & 0xf0 == 0x80 ? 1 : 2 }
                    else { bit = message.status & 0xf0 == 0xe0 ? 4 : 8 }
                    self.attempted.append(.init(message: message, neutral: neutral, range: range, bit: bit))
                    let succeeded = failures[message.status & 15] & bit == 0
                    self.gates.record(message, succeeded: succeeded)
                    if let neutral { self.controllers.record(message, neutral: neutral, succeeded: succeeded) }
                    return succeeded
                }, completeRange: { channel in
                    self.completedRanges.append(channel)
                    self.controllers.completeRange(channel: channel)
                })
        }
    }

    @Test(arguments: [false, true]) @MainActor
    func mixedChannelsRetainExactOrderAndIndependentDebt(reversed: Bool) throws {
        let order = Self.expectedOrder()
        let clear = Array(repeating: 0, count: 16)
        for seed in 0...63 {
            let failures = (0...15).map { (seed + $0 * 7) % 64 }
            let service = Service(reversed: reversed)
            let slot = NativeHelperRelativeHostLifetime<Service>()
            let token = try #require(slot.install(service))
            service.stop(failures: failures)
            #expect(service.attempted == order)
            #expect(service.completedRanges == (0...15).filter { failures[$0] & 48 == 0 })
            #expect(service.controllers.pendingRanges == (0...15).filter { failures[$0] & 48 != 0 })
            let closed = slot.close(token, retire: { _ in }, finish: { $0.finish() })
            #expect(!closed)
            #expect(slot.phase == .closing)
            let expectedRetry = order.filter { attempt in
                let mask = failures[attempt.message.status & 15]
                return mask & (attempt.range ? 48 : attempt.bit) != 0
            }
            service.stop(failures: clear)
            #expect(service.attempted == expectedRetry)
            #expect(service.completedRanges == (0...15).filter { failures[$0] & 48 != 0 })
            #expect(!service.pending)
            let recovered = slot.retry(token, finish: { $0.finish() })
            #expect(recovered)
            #expect(slot.phase == .idle)
            service.stop(failures: Array(repeating: 63, count: 16))
            #expect(service.attempted.isEmpty)
            #expect(service.completedRanges.isEmpty)
        }
    }
}
