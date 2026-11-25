import Foundation
import Testing
@testable import NoSpeakerCore

private func dynamicPoolFixture() throws -> DynamicMPEPoolPlan {
    var scale = CustomScale()
    scale.centOffsets = [2:20]
    let pitches = (36...83).filter { scale.intervals.contains(($0-60+144)%12) }
    let patch = InstrumentPatch(name:"Wide scale",routes:pitches.enumerated().map { i,note in
        .init(id:"n\(i)",source:.gamepad1,signal:.padA,destination:.init(.note,channel:3,number:note))
    } + [
        .init(id:"pedal",source:.gamepad1,signal:.padRT,destination:.init(.sustain,channel:3)),
        .init(id:"bend",source:.gamepad1,signal:.padLSX,destination:.init(.pitchBend,channel:3))
    ])
    return try .init(patch:patch,specification:.init(scale:scale,root:60))
}
private func poolNote(_ note:Int,_ value:Int) -> SensorCommand { .init(.init(.note,channel:3,number:note),value:value) }

@Test func dynamicPoolPlaysMoreThanFifteenMappedPitchesWithoutRetuningMembers() throws {
    let plan = try dynamicPoolFixture()
    #expect(plan.mappedNoteCount == 28 && plan.members.count == 15)
    #expect(Set(plan.members.map(\.channel)) == Set(1...15))
    #expect(plan.channelsPerBend.count == 2)
    var pool = DynamicMPEPoolSession(plan:plan)
    var sent:[SensorCommand] = []
    let sink:(SensorCommand)->Bool = { sent.append($0);return true }
    let prepared = pool.prepare(send:sink)
    #expect(prepared)
    sent.removeAll()
    let scale = CustomScale()
    for pitch in (36...83).filter({ scale.intervals.contains(($0-60+144)%12) }) {
        let on = pool.receive(poolNote(pitch,100),send:sink)
        let off = pool.receive(poolNote(pitch,0),send:sink)
        #expect(on == .delivered && off == .delivered)
    }
    #expect(sent.count == 56 && sent.allSatisfy { $0.destination.kind == .note })
    for i in stride(from:0,to:sent.count,by:2) {
        #expect(sent[i].destination == sent[i+1].destination)
        let note = sent[i].destination.number
        let expected = note%12 == 2 ? plan.members.map(\.bend).max() : 8192
        #expect(plan.members.first(where:{ $0.channel == sent[i].destination.channel })?.bend == expected)
    }
    #expect(pool.activeCount == 0 && pool.reservedCount == 0)
}

@Test func dynamicPoolSustainReservesMembersAndCapacityNeverStealsOrReplays() throws {
    let plan = try dynamicPoolFixture()
    var pool = DynamicMPEPoolSession(plan:plan)
    let prepared = pool.prepare { _ in true }
    #expect(prepared)
    var sent:[SensorCommand] = []
    let sink:(SensorCommand)->Bool = { sent.append($0);return true }
    let pedal = SensorDestination(.sustain,channel:3)
    _ = pool.receive(.init(pedal,value:127),send:sink)
    let capacity = try #require(plan.channelsPerBend[8192])
    for _ in 0..<capacity {
        let on = pool.receive(poolNote(36,100),send:sink)
        let off = pool.receive(poolNote(36,0),send:sink)
        #expect(on == .delivered && off == .delivered)
    }
    #expect(pool.activeCount == 0 && pool.reservedCount == capacity)
    #expect(Set(sent.filter { $0.destination.kind == .note && $0.value > 0 }.map(\.destination.channel)).count == capacity)
    sent.removeAll()
    let refused = pool.receive(poolNote(36,100),send:sink)
    #expect(refused == .capacity && pool.suppressedCount == 1 && sent.isEmpty)
    _ = pool.receive(.init(pedal,value:0),send:sink)
    let stillHeld = pool.receive(poolNote(36,100),send:sink)
    #expect(stillHeld == .ignored && pool.reservedCount == 0)
    _ = pool.receive(poolNote(36,0),send:sink)
    let reattack = pool.receive(poolNote(36,100),send:sink)
    #expect(reattack == .delivered && pool.suppressedCount == 0)
    #expect(sent.count == 2 && sent[0].destination == .init(.sustain) && sent[1].destination.kind == .note)
}

@Test func dynamicPoolAmbiguousAttackFailureRetainsExactWireDebtAndNeverRearms() throws {
    let plan = try dynamicPoolFixture()
    var pool = DynamicMPEPoolSession(plan:plan)
    let prepared = pool.prepare { _ in true }
    #expect(prepared)
    var attempted:[SensorCommand] = []
    let failed = pool.receive(poolNote(38,100)) { attempted.append($0);return false }
    #expect(failed == .failed && pool.state == .retired && pool.pendingCleanup)
    #expect(attempted.count == 2 && attempted[0].destination == attempted[1].destination)
    #expect(attempted[1].value == 0)
    var retry:[SensorCommand] = []
    let clean = pool.retryCleanup { retry.append($0);return true }
    #expect(clean && retry == [attempted[1]] && !pool.pendingCleanup)
    let later = pool.receive(poolNote(38,100)) { _ in Issue.record("retired port emitted");return true }
    #expect(later == .notReady)
}

@Test func dynamicPoolSetupFailureAndInvalidControlsFailClosed() throws {
    let plan = try dynamicPoolFixture()
    var pool = DynamicMPEPoolSession(plan:plan)
    let prepared = pool.prepare { _ in false }
    #expect(!prepared && pool.pendingCleanup && pool.state == .retired)
    let clean = pool.retryCleanup { _ in true }
    #expect(clean && !pool.pendingCleanup)
    let again = pool.prepare { _ in Issue.record("retired setup");return true }
    #expect(!again)
    var live = DynamicMPEPoolSession(plan:plan)
    _ = live.prepare { _ in true }
    let bad = live.receive(.init(.init(.controlChange,channel:3,number:66),value:127)) { _ in Issue.record("unsupported CC");return true }
    #expect(bad == .invalid)
    let foreign = live.receive(.init(.init(.note,channel:4,number:38),value:100)) { _ in Issue.record("foreign channel");return true }
    #expect(foreign == .invalid)
}


@Test func dynamicPoolFailedMasterPedalReleaseRetainsReservationDebt() throws {
    let plan = try dynamicPoolFixture()
    var pool = DynamicMPEPoolSession(plan:plan)
    _ = pool.prepare { _ in true }
    let pedal = SensorDestination(.sustain,channel:3)
    _ = pool.receive(.init(pedal,value:127)) { _ in true }
    _ = pool.receive(poolNote(38,100)) { _ in true }
    _ = pool.receive(poolNote(38,0)) { _ in true }
    #expect(pool.reservedCount == 1 && pool.activeCount == 0)
    var attempted:[SensorCommand] = []
    let failed = pool.receive(.init(pedal,value:0)) { attempted.append($0);return false }
    #expect(failed == .failed && pool.pendingCleanup && pool.reservedCount == 1)
    #expect(attempted == [.init(.init(.sustain),value:0),.init(.init(.sustain),value:0)])
    attempted.removeAll()
    let clean = pool.retryCleanup { attempted.append($0);return true }
    #expect(clean && pool.reservedCount == 0 && !pool.pendingCleanup)
    #expect(attempted == [.init(.init(.sustain),value:0)])
}
