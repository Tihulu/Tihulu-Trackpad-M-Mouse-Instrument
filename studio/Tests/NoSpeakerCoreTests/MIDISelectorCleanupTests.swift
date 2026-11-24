import Testing
@testable import NoSpeakerCore

@Test func chordMPEPartialConfigurationRetriesOnlyOpenSelectorChannel() {
    let plan = ChordMPEState.configuration()
    // Two five-message zone transactions plus 16 six-message RPN
    // transactions and 16 bend messages.
    #expect(plan.count == 122)
    for failure in plan.indices {
        var ledger = MIDISelectorCleanup()
        var index = 0
        let configured = ledger.configure(plan) { _ in
            defer { index += 1 }
            return index != failure
        }
        #expect(!configured)
        #expect(index == failure + 1)
        let command = plan[failure]
        let channel = command.destination.channel
        var releases: [SensorCommand] = []
        let cleared = ledger.releaseAll { releases.append($0); return false }
        if command.destination.kind == .pitchBend {
            #expect(cleared)
            #expect(releases.isEmpty)
        } else {
            #expect(!cleared)
            #expect(releases == [
                .init(.init(.controlChange,channel:channel,number:101),value:127),
                .init(.init(.controlChange,channel:channel,number:100),value:127)
            ])
            var sent = 0
            let blocked = ledger.configure(plan) { _ in sent += 1; return true }
            #expect(!blocked)
            #expect(sent == 0)
            var retry: [SensorCommand] = []
            let recovered = ledger.releaseAll { retry.append($0); return true }
            #expect(recovered)
            #expect(retry == releases)
        }
        #expect(ledger.isEmpty)
        let rearmed = ledger.configure(plan,send:{ _ in true })
        #expect(rearmed)
        #expect(ledger.isEmpty)
    }
}

@Test func completedChordMPEConfigurationHasNoSelectorDebt() {
    var ledger = MIDISelectorCleanup()
    var sent: [SensorCommand] = []
    let plan = ChordMPEState.configuration()
    let configured = ledger.configure(plan) { sent.append($0); return true }
    #expect(configured)
    #expect(sent == plan)
    #expect(ledger.isEmpty)
    let released = ledger.releaseAll { _ in
        Issue.record("Completed configuration must not generate cleanup traffic")
        return false
    }
    #expect(released)
}
