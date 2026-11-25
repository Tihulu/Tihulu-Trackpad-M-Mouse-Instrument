import Foundation
import Testing
@testable import NoSpeakerCore

@Test func indexedRouterPreservesInitialNeutralAndStableTargetOrder() throws {
    let a = SensorDestination(.controlChange,channel:10,number:74)
    let b = SensorDestination(.controlChange,channel:2,number:11)
    let c = SensorDestination(.note,channel:2,number:60)
    var router = SensorRouter()
    try router.configure([
        .init(id:"c",source:.trackpad,signal:.x,destination:c),
        .init(id:"b",source:.trackpad,signal:.x,destination:b),
        .init(id:"a",source:.trackpad,signal:.x,destination:a)
    ])
    let session = try router.connect(.trackpad,now:1)
    func event(_ value:Double,_ seq:UInt64) -> SensorEvent {
        .init(session:session,signal:.x,value:value,sequence:seq,timestamp:1+Double(seq)*0.01)
    }
    let first = router.ingest(event(0,1),now:1.01)
    #expect(first == [.init(a,value:0),.init(b,value:0)])
    let duplicate = router.ingest(event(0,2),now:1.02)
    #expect(duplicate.isEmpty)
    let active = router.ingest(event(1,3),now:1.03)
    #expect(active == [.init(a,value:127),.init(b,value:127),.init(c,value:100)])
    let stopped = router.panic()
    #expect(stopped == [.init(a,value:0),.init(c,value:0)])
    try router.configure([.init(id:"new",source:.phone,signal:.y,destination:a)])
    let newSession = try router.connect(.phone,now:2)
    let oldSignal = router.ingest(.init(session:newSession,signal:.x,value:1,sequence:1,timestamp:2),now:2)
    #expect(oldSignal.isEmpty)
    let newSignal = router.ingest(.init(session:newSession,signal:.y,value:1,sequence:2,timestamp:2.01),now:2.01)
    #expect(newSignal == [.init(a,value:127)])
}

@Test func indexedRouterMatchesIndependentPriorityOracleAtFullCapacity() throws {
    let target = SensorDestination(.controlChange,number:74)
    let note = SensorDestination(.note,number:60)
    let sources = SensorSource.allCases.filter { !GamepadFrame.sources.contains($0) }
    let routes = (0..<64).map { i in
        SensorMapping(id:"route-\(i)",source:sources[i%sources.count],signal:.x,
                      destination:i%3 == 0 ? note : target,priority:i%5,velocity:80+i%30)
    }
    var router = SensorRouter()
    try router.configure(routes)
    let ids = try (0..<16).map { try router.connect(sources[$0%sources.count],now:1) }
    var values: [Int:Double] = [:]
    var lastCC: Int?
    var lastGate = false
    var sequences = Array(repeating:UInt64(0),count:16)
    for step in 0..<2048 {
        let index = (step*7)%16
        let value = Double((step*37)%101)/100
        let now = 1+Double(step)*0.001
        sequences[index] += 1
        values[index] = value
        let active = values.flatMap { pair in
            routes.filter { $0.source == sources[pair.key%sources.count] }.map {
                (route:$0,session:ids[pair.key],value:pair.value)
            }
        }
        let winner = active.filter { $0.route.destination == target }.sorted {
            if $0.route.priority != $1.route.priority { return $0.route.priority > $1.route.priority }
            if $0.route.id != $1.route.id { return $0.route.id < $1.route.id }
            return $0.session.uuidString < $1.session.uuidString
        }.first
        // Gate hysteresis is checked separately in existing tests. This
        // oracle uses binary gate levels by replaying only values 0 or 1.
        let cc = winner.map { Int(($0.value*127).rounded()) }
        var expected:[SensorCommand] = []
        if cc != lastCC, let cc { expected.append(.init(target,value:cc)) }
        let actual = router.ingest(.init(session:ids[index],signal:.x,value:value,
            sequence:sequences[index],timestamp:now),now:now)
        #expect(actual.filter { $0.destination == target } == expected)
        let noteCommands = actual.filter { $0.destination == note }
        for command in noteCommands {
            #expect((command.value > 0) != lastGate)
            lastGate = command.value > 0
        }
        lastCC = cc
    }
    let final = router.panic()
    #expect(final.contains(.init(target,value:0)) == (lastCC != nil && lastCC != 0))
    #expect(final.contains(.init(note,value:0)) == lastGate)
    #expect(router.sessionCount == 0)
}

@Test func indexedRouterRetainsSubquantizedSmoothingState() throws {
    let target = SensorDestination(.controlChange,number:74)
    let response = ContinuousResponse(smoothingMS:100)
    var router = SensorRouter()
    try router.configure([.init(id:"smooth",source:.phone,signal:.x,destination:target,response:response)])
    let id = try router.connect(.phone,now:1)
    let first = router.ingest(.init(session:id,signal:.x,value:0,sequence:1,timestamp:1),now:1)
    #expect(first == [.init(target,value:0)])
    var filtered = 0.0
    var previous = 0
    var previousTime = 1.0
    for i in 1...1000 {
        let now = 1+Double(i)*0.001
        filtered = response.smooth(0.1,previous:filtered,elapsed:now-previousTime)
        let wire = response.output(filtered,target:target)
        let actual = router.ingest(.init(session:id,signal:.x,value:0.1,
            sequence:UInt64(i+1),timestamp:now),now:now)
        #expect(actual == (wire == previous ? [] : [.init(target,value:wire)]))
        previous = wire
        previousTime = now
    }
    #expect(previous == 13)
    let released = router.releaseSignal(session:id,signal:.x)
    #expect(released == [.init(target,value:0)])
}

@Test func indexedRouterFrameReleasesPreserveToggleUntilForcedCleanup() throws {
    let target = SensorDestination(.controlChange,number:80)
    var router = SensorRouter()
    try router.configure([.init(id:"toggle",source:.gamepad1,signal:.padA,destination:target,pedalMode:.toggle)])
    let session = try router.connect(.gamepad1,now:1)
    let on = router.ingestFrame(session:session,releasing:[],events:[
        .init(session:session,signal:.padA,value:1,sequence:1,timestamp:1)
    ],now:1)
    #expect(on == [.init(target,value:127)])
    for i in 1...100 {
        let lift = router.ingestFrame(session:session,releasing:[.padA,.padB],events:[],now:1+Double(i)*0.001)
        #expect(lift.isEmpty)
    }
    let clear = router.releaseSignal(session:session,signal:.padA)
    #expect(clear == [.init(target,value:0)])
    let stopped = router.panic()
    #expect(stopped.isEmpty)
}
