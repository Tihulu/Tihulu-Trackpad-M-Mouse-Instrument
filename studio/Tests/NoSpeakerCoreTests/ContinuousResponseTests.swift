import Foundation
import Testing
@testable import NoSpeakerCore

@Test func continuousResponseRangeReleaseAndGraphArchiveRoundTrip() throws {
    let target = SensorDestination(.controlChange, number: 4)
    let route = SensorMapping(id: "pedal", source: .trackpad, signal: .x, destination: target,
                              response: .init(minimum: 0.2, maximum: 0.8, release: 0.5))
    let patch = InstrumentPatch(routes: [route])
    #expect(try InstrumentPatch.read(patch.archive()) == patch)
    #expect(try PatchGraph(patch: patch).compile(name: patch.name) == patch)
    var sim = PatchSimulation()
    try sim.start(patch, now: 1)
    let input = PatchSimulation.Input(source: .trackpad, signal: .x)
    let min = sim.send(input, value: 0, now: 1.1)
    let max = sim.send(input, value: 1, now: 1.2)
    #expect(min == [.init(target, value: 25)])
    #expect(max == [.init(target, value: 102)])
    #expect(sim.stop() == [.init(target, value: 64)])
}

@Test func continuousResponseSmoothingUsesTimeAndReleaseBypassesFilter() throws {
    let target = SensorDestination(.controlChange, number: 4)
    let patch = InstrumentPatch(routes: [
        .init(id: "smooth", source: .trackpad, signal: .x, destination: target,
              response: .init(smoothingMS: 100, release: 0.25))
    ])
    var sim = PatchSimulation()
    try sim.start(patch, now: 1)
    let input = PatchSimulation.Input(source: .trackpad, signal: .x)
    let first = sim.send(input, value: 0, now: 1)
    #expect(first == [.init(target, value: 0)])
    let halfway = sim.send(input, value: 1, now: 1.1)
    #expect(halfway == [.init(target, value: 80)])
    let next = sim.send(input, value: 1, now: 1.2)
    #expect(next == [.init(target, value: 110)])
    #expect(sim.disconnect(.trackpad) == [.init(target, value: 32)])
}

@Test func customReleaseLedgerRetriesExactValueAndCannotChangePolicyWhileOutstanding() throws {
    let target = SensorDestination(.controlChange, number: 4)
    let patch = InstrumentPatch(routes: [
        .init(id: "release", source: .trackpad, signal: .x, destination: target, response: .init(release: 0.5))
    ])
    var ledger = PatchOutputLedger()
    try ledger.configure(patch)
    let delivered = ledger.deliver(.init(target, value: 120), send: { _ in true })
    #expect(delivered)
    #expect(throws: WorkspaceArchiveError.invalidPayload) { try ledger.configure(.starter) }
    var attempts: [SensorCommand] = []
    let failed = ledger.releaseAll(send: { attempts.append($0); return false })
    #expect(!failed)
    let retry = ledger.releaseAll(send: { attempts.append($0); return true })
    #expect(retry && ledger.outstanding.isEmpty)
    #expect(attempts == [.init(target, value: 64),.init(target, value: 64)])
}

@Test func continuousResponseRejectsConflictingReleaseAndGateModification() throws {
    let target = SensorDestination(.controlChange, number: 4)
    let a = SensorMapping(id: "a", source: .trackpad, signal: .x, destination: target, response: .init(release: 0.5))
    var b = SensorMapping(id: "b", source: .phone, signal: .x, destination: target)
    var router = SensorRouter()
    #expect(!InstrumentPatch(routes: [a,b]).isValid)
    #expect(throws: SensorRouterError.invalidMappings) { try router.configure([a,b]) }
    b.response = .init(release: 0.5)
    try router.configure([a,b])
    b.destination = .init(.note, number: 60)
    #expect(!b.isValid)
    #expect(!ContinuousResponse(minimum: 0.9, maximum: 0.2).isValid)
}

@Test func legacyPatchWithoutResponseDecodesAndNewPanReturnsCenter() throws {
    let json = """
    {"id":"old","source":"trackpad","signal":"x","destination":{"kind":"controlChange","channel":0,"number":74},"calibration":{"minimum":0,"maximum":1,"inverted":false,"deadZone":0,"exponent":1},"priority":0,"threshold":0.55,"hysteresis":0.08,"velocity":100}
    """
    let old = try JSONDecoder().decode(SensorMapping.self, from: Data(json.utf8))
    #expect(old.response == nil && old.isValid)
    let pan = try ExpressivePreset.pan.appending(to: .init(), source: .trackpad, signal: .x, channel: 0)
    #expect(pan.routes.first?.response?.releaseValue(for: .init(.controlChange, number: 10)) == 64)
}

@Test func relativeControlAnchorsWithoutSendingAndReturnsToOrigin() throws {
    let target = SensorDestination(.pitchBend)
    var router = SensorRouter()
    try router.configure([.init(id: "relative", source: .magicMouse, signal: .x,
        destination: target, response: .init(relative: .init(reference: 8192.0 / 16383)))])
    let id = try router.connect(.magicMouse, now: 1)
    func event(_ x: Double, _ sequence: UInt64) -> SensorEvent {
        .init(session: id, signal: .x, value: x, sequence: sequence, timestamp: Double(sequence))
    }
    #expect(router.ingest(event(0.75, 1), now: 1).isEmpty)
    #expect(router.ingest(event(0.875, 2), now: 2) == [.init(target, value: 10240)])
    #expect(router.ingest(event(0.75, 3), now: 3) == [.init(target, value: 8192)])
    #expect(router.releaseSignal(session: id, signal: .x).isEmpty)
    #expect(router.ingest(event(0.25, 4), now: 4).isEmpty)
    #expect(router.ingest(event(0.125, 5), now: 5) == [.init(target, value: 6144)])
    #expect(router.disconnect(id) == [.init(target, value: 8192)])
}

@Test func relativeControlClampsWithoutDriftAndRejectsInvalidReferences() throws {
    var gesture = try #require(RelativeControlGesture(input: 0.5, timestamp: 0,
        reference: 90, lower: 0, upper: 127, gain: 2))
    #expect(gesture.update(input: 1, timestamp: 1) == 127)
    #expect(gesture.update(input: 0.9, timestamp: 2) == nil)
    #expect(gesture.update(input: .nan, timestamp: 3) == nil)
    #expect(gesture.update(input: 0.5, timestamp: 3) == 90)
    #expect(gesture.update(input: 0, timestamp: 4) == 0)
    #expect(gesture.update(input: 0.5, timestamp: 5) == 90)
    #expect(RelativeControlGesture(input: 0, timestamp: 0, reference: 128, lower: 0, upper: 127) == nil)
}

@Test func relativeControlRejectsSwitchesAndSharedDestinationsAndRoundTrips() throws {
    let target = SensorDestination(.controlChange, number: 74)
    let route = SensorMapping(id: "delta", source: .camera, signal: .x,
        destination: target, response: .init(relative: .init(reference: 0.7, gain: 2)))
    let patch = InstrumentPatch(routes: [route])
    #expect(patch.isValid)
    #expect(try InstrumentPatch.read(patch.archive()) == patch)
    #expect(try PatchGraph(patch: patch).compile(name: patch.name) == patch)
    var other = route
    other.id = "other"; other.source = .phone
    #expect(!InstrumentPatch(routes: [route, other]).isValid)
    other.destination = .init(.controlChange, number: 65)
    #expect(!other.isValid)
    other.destination = target; other.signal = .contact
    #expect(!other.isValid)
}

@Test func relativeControlAnchorOnlyReleaseAndSecondSessionIsolation() throws {
    let target = SensorDestination(.controlChange, number: 74)
    var router = SensorRouter()
    try router.configure([.init(id: "relative", source: .trackpad, signal: .x,
        destination: target, response: .init(relative: .init(reference: 0.5)))])
    let a = try router.connect(.trackpad, now: 0)
    let b = try router.connect(.trackpad, now: 0)
    #expect(router.ingest(.init(session: a, signal: .x, value: 0.8, sequence: 1, timestamp: 1), now: 1).isEmpty)
    #expect(router.ingest(.init(session: b, signal: .x, value: 0.2, sequence: 1, timestamp: 1), now: 1).isEmpty)
    #expect(router.releaseSignal(session: a, signal: .x).isEmpty)
    #expect(router.ingest(.init(session: b, signal: .x, value: 0.4, sequence: 2, timestamp: 2), now: 2).isEmpty)
    #expect(router.ingest(.init(session: b, signal: .x, value: 0.5, sequence: 3, timestamp: 3), now: 3).isEmpty)
    #expect(router.releaseSignal(session: b, signal: .x).isEmpty)
    #expect(router.ingest(.init(session: b, signal: .x, value: 0.4, sequence: 4, timestamp: 4), now: 4).isEmpty)
    #expect(router.ingest(.init(session: b, signal: .x, value: 0.5, sequence: 5, timestamp: 5), now: 5) == [.init(target, value: 77)])
    #expect(router.panic() == [.init(target, value: 0)])
}

@Test func relativeReferenceEvidenceRejectsWrongSourceTimeAndRange() {
    let sample = RelativeReferenceEvidence(source: .receiverConfirmed, value: 90, observedAt: 1)
    #expect(sample.permits(source: .receiverConfirmed, lower: 0, upper: 127, now: 1.25))
    #expect(!sample.permits(source: .receiverConfirmed, lower: 0, upper: 127, now: 1.251))
    #expect(!sample.permits(source: .receiverConfirmed, lower: 0, upper: 127, now: 0.99))
    #expect(!sample.permits(source: .receiverConfirmed, lower: 0, upper: 80, now: 1))
    #expect(!sample.permits(source: .lastDelivered, lower: 0, upper: 127, now: 1))
    #expect(!sample.permits(source: .receiverConfirmed, lower: 0, upper: 127, now: .nan))
}

@Test func relativeReferenceRequiresFreshScopedEvidenceAndNewClutch() throws {
    let target = SensorDestination(.controlChange, number: 74)
    let route = SensorMapping(id: "feedback", source: .magicMouse, signal: .x,
        destination: target, response: .init(relative: .init(reference: 0.5, referenceSource: .receiverConfirmed)))
    var router = SensorRouter()
    try router.configure([route])
    let id = try router.connect(.magicMouse, now: 0)
    func event(_ x: Double, _ sequence: UInt64, _ time: Double) -> SensorEvent {
        .init(session: id, signal: .x, value: x, sequence: sequence, timestamp: time)
    }
    func evidence(_ time: Double) -> RelativeReferenceEvidence {
        .init(source: .receiverConfirmed, value: 90, observedAt: time)
    }
    #expect(router.ingest(event(0.5, 1, 1), now: 1).isEmpty)
    let referenceResult1 = router.provideRelativeReference(session: id, mappingID: route.id, destination: target, evidence: evidence(1), now: 1)
    #expect(!referenceResult1)
    #expect(router.releaseSignal(session: id, signal: .x).isEmpty)
    let referenceResult2 = router.provideRelativeReference(session: id, mappingID: route.id, destination: .init(.controlChange, number: 71), evidence: evidence(2), now: 2)
    #expect(!referenceResult2)
    let referenceResult3 = router.provideRelativeReference(session: id, mappingID: route.id, destination: target, evidence: evidence(2), now: 2)
    #expect(referenceResult3)
    #expect(router.ingest(event(0.5, 2, 2), now: 2).isEmpty)
    #expect(router.ingest(event(0.6, 3, 2.1), now: 2.1) == [.init(target, value: 103)])
    let referenceResult4 = router.provideRelativeReference(session: id, mappingID: route.id, destination: target, evidence: evidence(2.1), now: 2.1)
    #expect(!referenceResult4)
    #expect(router.releaseSignal(session: id, signal: .x) == [.init(target, value: 0)])
    #expect(router.ingest(event(0.5, 4, 3), now: 3).isEmpty)
    #expect(router.ingest(event(0.8, 5, 3.1), now: 3.1).isEmpty)
}

@Test func relativeReferenceCannotReplayConsumedOrDiscardedEvidence() throws {
    let target = SensorDestination(.controlChange, number: 74)
    let route = SensorMapping(id: "last", source: .trackpad, signal: .x,
        destination: target, response: .init(relative: .init(reference: 0.5, referenceSource: .lastDelivered)))
    var router = SensorRouter()
    try router.configure([route])
    let id = try router.connect(.trackpad, now: 0)
    func evidence(_ t: Double) -> RelativeReferenceEvidence {
        .init(source: .lastDelivered, value: 80, observedAt: t)
    }
    // Even a reference discarded before movement cannot be re-used.
    let referenceResult5 = router.provideRelativeReference(session: id, mappingID: route.id, destination: target, evidence: evidence(1), now: 1)
    #expect(referenceResult5)
    #expect(router.releaseSignal(session: id, signal: .x).isEmpty)
    let referenceResult6 = router.provideRelativeReference(session: id, mappingID: route.id, destination: target, evidence: evidence(1), now: 1.1)
    #expect(!referenceResult6)
    let referenceResult7 = router.provideRelativeReference(session: id, mappingID: route.id, destination: target, evidence: evidence(1.1), now: 1.1)
    #expect(referenceResult7)
    #expect(router.ingest(.init(session: id, signal: .x, value: 0.4, sequence: 1, timestamp: 1.1), now: 1.1).isEmpty)
    #expect(router.ingest(.init(session: id, signal: .x, value: 0.5, sequence: 2, timestamp: 1.2), now: 1.2) == [.init(target, value: 93)])
    #expect(router.releaseSignal(session: id, signal: .x) == [.init(target, value: 0)])
    let referenceResult8 = router.provideRelativeReference(session: id, mappingID: route.id, destination: target, evidence: evidence(1.1), now: 1.21)
    #expect(!referenceResult8)
    let referenceResult9 = router.provideRelativeReference(session: id, mappingID: route.id, destination: target, evidence: evidence(1.15), now: 1.21)
    #expect(!referenceResult9)
    let referenceResult10 = router.provideRelativeReference(session: id, mappingID: route.id, destination: target, evidence: evidence(1.21), now: 1.21)
    #expect(referenceResult10)
    #expect(router.disconnect(id).isEmpty)
    let referenceResult11 = router.provideRelativeReference(session: id, mappingID: route.id, destination: target, evidence: evidence(1.22), now: 1.22)
    #expect(!referenceResult11)
}

@Test func relativeControlRejectsAmbiguousPedalAndWrappedAngleLanesUntilBound() {
    for signal in [SensorSignal.pedalExpression, .pedalVolume, .pedalWah, .tiltYaw, .tiltPitch] {
        let absolute = SensorMapping(id: "lane", source: .phone, signal: signal,
            destination: .init(.controlChange, number: 74))
        #expect(absolute.isValid)
        var relative = absolute
        relative.response = .init(relative: .init(reference: 0.5))
        #expect(!relative.isValid)
    }
    for signal in [SensorSignal.x, .y, .tiltRoll, .rotationMagnitude] {
        let route = SensorMapping(id: "level", source: .phone, signal: signal,
            destination: .init(.controlChange, number: 74),
            response: .init(relative: .init(reference: 0.5)))
        #expect(route.isValid)
    }
}
