import Testing
@testable import NoSpeakerCore

@Test(arguments: Array(0..<16))
func sequencerRecoveryIsolatesSimultaneousChannelDebt(selectorChannel: Int) {
    let keys = (0..<16).flatMap { channel in
        [36, 60].map { SensorDestination(.note, channel: channel, number: $0) }
    }
    let nulls: [SensorCommand] = [
        .init(.init(.controlChange, channel: selectorChannel, number: 101), value: 127),
        .init(.init(.controlChange, channel: selectorChannel, number: 100), value: 127)
    ]
    for seed in 0..<8 {
        for selectorFailure in 0..<4 {
            var notes = MIDIClipNoteLedger()
            var selectors = MIDISelectorCleanup()
            for key in keys.reversed() {
                let delivered = notes.deliver(.init(key, value: 90)) { _ in
                    (key.channel + key.number + seed) % 3 != 0
                }
                #expect(delivered == ((key.channel + key.number + seed) % 3 != 0))
            }
            #expect(notes.outstanding == Set(keys))
            // One incomplete transaction, as in an ordered MPE setup.
            let configured = selectors.configure([
                .init(.init(.controlChange, channel: selectorChannel, number: 101), value: 0),
                .init(.init(.controlChange, channel: selectorChannel, number: 100), value: 0)
            ]) { $0.destination.number != 100 }
            #expect(!configured && !selectors.isEmpty)
            var expectedNotes = keys
            var expectedSelector = true
            for round in 0..<3 {
                let expectedWire = expectedNotes.map { SensorCommand($0, value: 0) }
                    + (expectedSelector ? nulls : [])
                func fails(_ command: SensorCommand) -> Bool {
                    if round == 2 { return false }
                    let key = command.destination
                    if key.kind == .note {
                        return (key.channel + (key.number == 36 ? 0 : 1) + seed + round) % (round == 0 ? 3 : 2) == 0
                    }
                    if round == 1 { return key.number == 100 && seed.isMultiple(of: 2) }
                    let bit = key.number == 101 ? 1 : 2
                    return selectorFailure & bit != 0
                }
                var wire: [SensorCommand] = []
                let clean = SequencerMIDIRecovery.release(notes: &notes, selectors: &selectors) { command in
                    wire.append(command)
                    return !fails(command)
                }
                #expect(wire == expectedWire)
                expectedNotes = expectedNotes.filter { fails(.init($0, value: 0)) }
                expectedSelector = expectedSelector && nulls.contains(where: fails)
                #expect(notes.outstanding == Set(expectedNotes))
                #expect(selectors.isEmpty == !expectedSelector)
                #expect(clean == (expectedNotes.isEmpty && !expectedSelector))
            }
            #expect(notes.outstanding.isEmpty && selectors.isEmpty)
            var extra = 0
            let settled = SequencerMIDIRecovery.release(notes: &notes, selectors: &selectors) { _ in
                extra += 1
                return false
            }
            #expect(settled && extra == 0)
        }
    }
}
