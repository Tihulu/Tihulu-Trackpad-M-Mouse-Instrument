import Foundation
import Testing
@testable import NoSpeakerCore

private func reservationPlan() throws -> CustomSurfaceMixedPlan {
    let layout = try #require(CustomSurfacePadLayout(surface: .trackpad, pads: [
        .init(id: "note", label: "Note", x: 0, y: 0, width: 10000, height: 10000, assignment: .note(60))
    ]))
    return try .init(layout: layout, melodicChannel: 2)
}
private let reservationContact = CustomSurfaceContactProjection.Contact(id: 1, x: 0.5, y: 0.5)
private let reservationNote = SensorDestination(.note, channel: 2, number: 60)

@Test func customPadReservationQuarantinesLostIncarnationUntilOriginalCleanup() throws {
    let registry = CustomSurfaceEndpointReservations()
    let plan = try reservationPlan()
    let original = UUID(), replacement = UUID()
    var current = original
    var now: Int64 = 0
    var wire: [SensorCommand] = []
    func open(_ incarnation: UUID) -> CustomSurfaceEndpointReservations.Lease? {
        registry.open(endpointID: 42, incarnation: incarnation, plan: plan, clock: { now },
            admitsLive: { true }, ownsEndpoint: { _, id in id == current },
            send: { _, _, command in wire.append(command); return true })
    }
    let lease = try #require(open(original))
    #expect(open(original) == nil)
    _ = registry.frame(lease, contacts: [], sequence: 1, observedAt: 0)
    now = 1
    _ = registry.frame(lease, contacts: [reservationContact], sequence: 2, observedAt: 1)
    #expect(wire.count == 1)
    current = replacement
    let stopped = try #require(registry.close(lease))
    #expect(stopped.pendingCleanup == Set([reservationNote]))
    #expect(open(replacement) == nil)
    #expect(registry.retryCleanup(lease)?.pendingCleanup == Set([reservationNote]))
    #expect(wire.count == 1)
    #expect(registry.reservedIDs == Set([42]))
    current = original
    #expect(registry.retryCleanup(lease)?.pendingCleanup.isEmpty == true)
    #expect(wire.last == .init(reservationNote, value: 0))
    #expect(registry.reservedIDs.isEmpty)
    current = replacement
    let next = try #require(open(replacement))
    #expect(next != lease)
    #expect(registry.close(lease) == nil)
    #expect(registry.frame(lease, contacts: [], sequence: 3, observedAt: 1) == nil)
    #expect(registry.reservedIDs == Set([42]))
    #expect(registry.close(next)?.retired == true)
}
@Test func customPadReservationIsolatesEndpointsAndRefusesUnownedRegistration() throws {
    let registry = CustomSurfaceEndpointReservations()
    let plan = try reservationPlan()
    let incarnation = UUID()
    var now: Int64 = 0
    var wire: [Int32] = []
    func open(_ id: Int32, owned: Bool = true) -> CustomSurfaceEndpointReservations.Lease? {
        registry.open(endpointID: id, incarnation: incarnation, plan: plan, clock: { now },
            admitsLive: { true }, ownsEndpoint: { _, _ in owned },
            send: { endpoint, _, _ in wire.append(endpoint); return true })
    }
    #expect(open(0) == nil)
    #expect(open(43, owned: false) == nil)
    let first = try #require(open(42))
    let second = try #require(open(43))
    for lease in [first, second] { _ = registry.frame(lease, contacts: [], sequence: 1, observedAt: 0) }
    now = 1
    for lease in [first, second] { _ = registry.frame(lease, contacts: [reservationContact], sequence: 2, observedAt: 1) }
    #expect(registry.retryCleanup(second)?.retired == false)
    #expect(registry.close(first)?.pendingCleanup.isEmpty == true)
    #expect(registry.reservedIDs == Set([43]))
    #expect(wire == [42, 43, 42])
    #expect(registry.close(second)?.pendingCleanup.isEmpty == true)
    #expect(wire == [42, 43, 42, 43])
}
