import Foundation
import Testing
import NoSpeakerCore

// Deliberately do not use @testable: the native host is a separate module.
@Test func groupRemotePublicBoundaryCanConstructEmptyBatchAndInspectSlots() {
    var batch = PerformanceGroupRemoteBatch()
    batch.actions = [.stop]
    #expect(batch.actions == [.stop])
    #expect(batch.reports.isEmpty && !batch.fault)
    let bridge = PerformanceGroupRemoteBridge()
    #expect(bridge.connectionSlots.isEmpty && bridge.connectionIDs.isEmpty)
}
