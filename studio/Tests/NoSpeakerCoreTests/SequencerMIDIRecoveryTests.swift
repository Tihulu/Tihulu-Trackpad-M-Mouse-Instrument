import Testing
@testable import NoSpeakerCore

@Test(arguments: Array(0..<16))
func sequencerRecoveryPreservesMixedDebtAndOriginalSendOrder(channel: Int) {
    let low = SensorDestination(.note, channel: channel, number: 36)
    let high = SensorDestination(.note, channel: channel, number: 60)
    let msb = SensorDestination(.controlChange, channel: channel, number: 101)
    let lsb = SensorDestination(.controlChange, channel: channel, number: 100)
    let expected: [SensorCommand] = [.init(low, value: 0), .init(high, value: 0),
                                     .init(msb, value: 127), .init(lsb, value: 127)]
    for onsetMask in 0..<4 {
        for failureMask in 0..<16 {
            var notes = MIDIClipNoteLedger()
            var selectors = MIDISelectorCleanup()
            // Reverse insertion verifies deterministic note order. A failed
            // attempted note-on can still have reached the receiver.
            let highOn = notes.deliver(.init(high, value: 90)) { _ in onsetMask & 2 == 0 }
            let lowOn = notes.deliver(.init(low, value: 90)) { _ in onsetMask & 1 == 0 }
            #expect(highOn == (onsetMask & 2 == 0))
            #expect(lowOn == (onsetMask & 1 == 0))
            #expect(notes.outstanding == [low, high])
            let configured = selectors.configure([.init(msb, value: 0)]) { _ in false }
            #expect(!configured && !selectors.isEmpty)
            var first: [SensorCommand] = []
            let clean = SequencerMIDIRecovery.release(notes: &notes, selectors: &selectors) { command in
                let index = first.count
                first.append(command)
                return failureMask & (1 << index) == 0
            }
            #expect(first == expected)
            #expect(clean == (failureMask == 0))
            let remaining = Set([low, high].enumerated().compactMap { index, key in
                failureMask & (1 << index) != 0 ? key : nil
            })
            #expect(notes.outstanding == remaining)
            #expect(selectors.isEmpty == (failureMask & 12 == 0))
            let retryExpected = expected.enumerated().compactMap { index, command in
                (index < 2 ? failureMask & (1 << index) != 0 : failureMask & 12 != 0) ? command : nil
            }
            var retry: [SensorCommand] = []
            let recovered = SequencerMIDIRecovery.release(notes: &notes, selectors: &selectors) {
                retry.append($0); return true
            }
            #expect(recovered && notes.outstanding.isEmpty && selectors.isEmpty)
            #expect(retry == retryExpected)
            var extra = 0
            let settled = SequencerMIDIRecovery.release(notes: &notes, selectors: &selectors) { _ in
                extra += 1; return false
            }
            #expect(settled && extra == 0)
        }
    }
}
