import Testing
@testable import NoSpeakerCore

@Test func builderCommandMonitorRetainsNewestFirstAndBoundsBatch() {
    let commands = (0..<40).map { SensorCommand(.init(.note,channel:1,number:$0),value:100) }
    let history = BuilderCommandMonitor.updated(["older"],attempted:commands)
    #expect(history.count == 24)
    #expect(history.first == "Ch 2 · note 39 → 100")
    #expect(history.last == "Ch 2 · note 16 → 100")
    let next = BuilderCommandMonitor.updated(history,attempted:[.init(.init(.note,channel:1,number:39),value:0)])
    #expect(next.count == 24 && next.first == "Ch 2 · note 39 → 0")
    #expect(next[1] == history[0])
    #expect(BuilderCommandMonitor.updated(next,attempted:[]) == next)
}
@Test func builderCommandMonitorOnlyIncludesAttemptedPrefix() {
    let commands = [SensorCommand(.init(.controlChange,number:74),value:50),.init(.init(.note,number:60),value:100)]
    let history = BuilderCommandMonitor.updated(["previous"],attempted:Array(commands.prefix(1)))
    #expect(history == ["Ch 1 · controlChange 74 → 50","previous"])
}
