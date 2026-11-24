import Testing
@testable import NoSpeakerCore

@Test func midiScheduleOrdersOffBeforeOnAndPreservesClipBoundary() throws {
    let clip = try MIDIClip.melody(.init(bpm: 120, steps: [
        .init(index: 0, midi: 60, gate: 1), .init(index: 1, midi: 60, gate: 1)
    ]))
    let schedule = try MIDIClipSchedule(clip)
    #expect(schedule.events.map(\.tick) == [0,240,240,480])
    #expect(schedule.events.map(\.isNoteOn) == [true,false,true,false])
    #expect(schedule.events[0].endTick == 240)
    #expect(schedule.seconds(at: schedule.length) == 2)
}

@Test func midiLedgerRetainsFailedOnAndRetriesRelease() {
    var ledger = MIDIClipNoteLedger()
    let key = SensorDestination(.note, channel: 9, number: 36)
    let on = SensorCommand(key, value: 100)
    let failedOn = ledger.deliver(on, send: { _ in false })
    #expect(!failedOn)
    #expect(ledger.outstanding.contains(key))
    let failedRelease = ledger.releaseAll(send: { _ in false })
    #expect(!failedRelease)
    #expect(ledger.outstanding.contains(key))
    var sent: [SensorCommand] = []
    let released = ledger.releaseAll(send: { sent.append($0); return true })
    #expect(released && ledger.outstanding.isEmpty)
    #expect(sent == [SensorCommand(key, value: 0)])
}

@Test func midiLedgerSkipsUnsentOffAndNeverReleasesOtherChannels() {
    var ledger = MIDIClipNoteLedger()
    let note = SensorDestination(.note, channel: 0, number: 60)
    let other = SensorDestination(.note, channel: 1, number: 60)
    var sent: [SensorCommand] = []
    let skipped = ledger.deliver(.init(other, value: 0), send: { sent.append($0); return true })
    #expect(skipped && sent.isEmpty)
    let on = ledger.deliver(.init(note, value: 90), send: { sent.append($0); return true })
    #expect(on)
    let duplicate = ledger.deliver(.init(note, value: 90), send: { sent.append($0); return true })
    #expect(!duplicate)
    let released = ledger.releaseAll(send: { sent.append($0); return true })
    #expect(released)
    #expect(sent.map(\.destination) == [note,note])
}
