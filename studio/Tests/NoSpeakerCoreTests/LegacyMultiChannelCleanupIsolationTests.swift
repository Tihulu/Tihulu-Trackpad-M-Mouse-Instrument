import Testing
@testable import NoSpeakerCore

/// Full-source recovery may own many channels at once. A successful release
/// must not clear the same note, controller or range on another channel.
@Test(arguments: Array(0..<16))
func legacyCleanupRetriesOnlyOutstandingMultiChannelObligations(seed: Int) {
    typealias Message = LegacyGateReleaseDebt.Message
    struct Wire: Equatable {
        let message: Message
        let neutral: Int?
        let range: Bool
    }
    let channels = Array(0..<16)
    var gates = LegacyGateReleaseDebt()
    var controllers = LegacyControllerReleaseDebt()
    for channel in channels.reversed() {
        let delivered = (channel + seed).isMultiple(of: 2)
        gates.record(.init(0xb0 | channel, 64, 127), succeeded: delivered)
        for note in [60, 36] {
            gates.record(.init(0x90 | channel, note, 90), succeeded: delivered)
        }
        controllers.record(.init(0xb0 | channel, 74, 90), neutral: channel, succeeded: delivered)
        controllers.record(.init(0xd0 | channel, 50, 0), neutral: 0, succeeded: delivered)
        controllers.record(.init(0xe0 | channel, 1, 65), neutral: 8192, succeeded: delivered)
        controllers.beginRange(channel: channel)
    }
    var expectedGates = channels.map { Wire(message: .init(0xb0 | $0, 64, 0), neutral: nil, range: false) }
    expectedGates += channels.flatMap { channel in
        [36, 60].map { Wire(message: .init(0x80 | channel, $0, 0), neutral: nil, range: false) }
    }
    var expectedRanges = channels
    var expectedControllers = channels.map { Wire(message: .init(0xb0 | $0, 74, $0), neutral: $0, range: false) }
    expectedControllers += channels.map { Wire(message: .init(0xd0 | $0, 0, 0), neutral: 0, range: false) }
    expectedControllers += channels.map { Wire(message: .init(0xe0 | $0, 0, 64), neutral: 8192, range: false) }
    func selectors(_ channel: Int) -> [Wire] {
        [101, 100].map { Wire(message: .init(0xb0 | channel, $0, 127), neutral: nil, range: true) }
    }
    for round in 0..<4 {
        func fails(_ wire: Wire) -> Bool {
            if round >= 2 { return false }
            let m = wire.message
            let channel = m.status & 15
            return (channel + m.data1 + (m.status >> 4) + seed + round).isMultiple(of: round == 0 ? 3 : 2)
        }
        let expectedWire = expectedGates + expectedRanges.flatMap(selectors) + expectedControllers
        if round == 0 { #expect(expectedWire.count == 128) }
        if round == 3 { #expect(expectedWire.isEmpty) }
        var actual: [Wire] = []
        var completedRanges: [Int] = []
        LegacyRecoveryPolicy.drainAttemptedCleanup(pendingGates: { gates.pending },
            pendingRanges: { controllers.pendingRanges }, pendingControllers: { controllers.pending },
            send: { message, neutral, range in
                let wire = Wire(message: message, neutral: neutral, range: range)
                actual.append(wire)
                let success = !fails(wire)
                #expect(LegacyRecoveryPolicy.permitsSend(enabled: false, faulted: true,
                    cleaning: true, unknownFailure: true))
                if LegacyGateReleaseDebt.isGate(message) { gates.record(message, succeeded: success) }
                if let neutral { controllers.record(message, neutral: neutral, succeeded: success) }
                return success
            }, completeRange: { channel in
                completedRanges.append(channel)
                controllers.completeRange(channel: channel)
            })
        #expect(actual == expectedWire)
        #expect(completedRanges == expectedRanges.filter { !selectors($0).contains(where: fails) })
        expectedGates = expectedGates.filter(fails)
        expectedRanges = expectedRanges.filter { selectors($0).contains(where: fails) }
        expectedControllers = expectedControllers.filter(fails)
        #expect(gates.pending == expectedGates.map(\.message))
        #expect(controllers.pendingRanges == expectedRanges)
        #expect(controllers.pending == expectedControllers.map(\.message))
        #expect(!LegacyRecoveryPolicy.permitsReplacement(gatesPending: !gates.isEmpty,
            controllersPending: !controllers.isEmpty, unknownFailure: true))
        #expect(!LegacyRecoveryPolicy.permitsSend(enabled: true, faulted: false,
            cleaning: false, unknownFailure: true))
    }
    #expect(gates.isEmpty && controllers.isEmpty)
    #expect(LegacyRecoveryPolicy.permitsReplacement(gatesPending: false,
        controllersPending: false, unknownFailure: false))
}
