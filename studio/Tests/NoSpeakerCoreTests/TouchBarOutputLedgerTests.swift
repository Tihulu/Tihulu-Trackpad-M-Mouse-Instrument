import Testing
@testable import NoSpeakerCore

@Test func dedicatedTouchBarRetriesOnlyUnconfirmedOriginalChannelControls() {
    var ledger = TouchBarOutputLedger()
    let note = SensorDestination(.note,channel:2,number:60)
    let bend = SensorDestination(.pitchBend,channel:2)
    let filter = SensorDestination(.controlChange,channel:2,number:74)
    let expression = SensorDestination(.controlChange,channel:2,number:11)
    let result1 = ledger.deliver(.init(note,value:90),send:{ _ in true })
    #expect(result1)
    let result2 = ledger.deliver(.init(bend,value:12000),send:{ _ in true })
    #expect(result2)
    let result3 = ledger.deliver(.init(filter,value:100),send:{ _ in true })
    #expect(result3)
    let result4 = ledger.deliver(.init(expression,value:45),send:{ _ in false })
    #expect(!result4)
    var attempted: [SensorCommand] = []
    #expect(!ledger.releaseAll { c in
        attempted.append(c)
        return c.destination == note || c.destination == filter
    })
    #expect(Set(attempted.map(\.destination)) == Set([note,bend,filter,expression]))
    #expect(attempted.contains(.init(filter,value:0)))
    #expect(attempted.contains(.init(expression,value:127)))
    attempted.removeAll()
    let result5 = ledger.configureBendRange(channel:3,send:{ _ in true })
    #expect(!result5)
    #expect(ledger.releaseAll { attempted.append($0); return true })
    #expect(attempted.count == 2)
    #expect(attempted.contains(.init(bend,value:8192)))
    #expect(attempted.contains(.init(expression,value:127)))
    #expect(ledger.isEmpty)
    let result6 = ledger.releaseAll(send:{ _ in false })
    #expect(result6)
}

@Test func dedicatedTouchBarPartialRPNFailureRetriesBothSelectors() {
    for failedIndex in 0..<6 {
        var ledger = TouchBarOutputLedger()
        var index = 0
        #expect(!ledger.configureBendRange(channel:5) { _ in
            defer { index += 1 }
            return index != failedIndex
        })
        var attempted: [SensorCommand] = []
        #expect(!ledger.releaseAll { attempted.append($0); return $0.destination.number == 100 })
        #expect(attempted == [.init(.init(.controlChange,channel:5,number:101),value:127),
                              .init(.init(.controlChange,channel:5,number:100),value:127)])
        #expect(!ledger.isEmpty)
        let result7 = ledger.configureBendRange(channel:6,send:{ _ in true })
        #expect(!result7)
        var retry: [SensorCommand] = []
        #expect(ledger.releaseAll { retry.append($0); return true })
        #expect(retry == attempted)
        let result8 = ledger.configureBendRange(channel:6,send:{ _ in true })
        #expect(result8)
        #expect(ledger.isEmpty)
    }
}
