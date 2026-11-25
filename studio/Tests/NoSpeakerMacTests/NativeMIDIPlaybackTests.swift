#if os(macOS)
import Foundation
import Testing
import NoSpeakerCore
@testable import NoSpeakerMac

private func nativePlaybackClip() -> MIDIClip {
    .init(bpm:120,length:960,notes:[.init(start:0,duration:480,channel:0,pitch:60,velocity:90)])
}

@Test @MainActor func nativePlaybackRejectsRunAndCloseWithoutOpen() async throws {
    let player=try NativeMIDIPlayback(clip:nativePlaybackClip())
    await #expect(throws:NativeMIDIPlayback.Failure.self) { _=try await player.run() }
    #expect(throws:NativeMIDIPlayback.Failure.self) { try player.close() }
    #expect(throws:NativeMIDIPlayback.Failure.self) { _=try player.retryCleanup() }
}

// Actual virtual CoreMIDI source; never activate a physical destination.
// Run only in an explicitly enabled disposable CI environment.
@Test(.enabled(if:ProcessInfo.processInfo.environment["TIHULU_NATIVE_OBSERVER_FIXTURE"] == "1" &&
                  ProcessInfo.processInfo.environment["CI"] == "true"))
@MainActor func nativePlaybackUsesIsolatedSourceAndClosesIt() async throws {
    let player=try NativeMIDIPlayback(clip:nativePlaybackClip())
    try player.open()
    defer { _=try? player.close() }
    #expect(throws:NativeMIDIPlayback.Failure.self) { try player.open() }
    var task:Task<NativeMIDIPlayback.Report,Error>?
    let observation=try await NativeMIDIMonitor.observe(sourceName:player.sourceName,seconds:2,onConnected:{
        task=Task { @MainActor in try await player.run() }
    })
    let running=try #require(task)
    let report=try await running.value
    #expect(report.state=="finished")
    #expect(report.cleanupConfirmed && report.outstandingNotes==0)
    #expect(!report.cancelled && !report.receiverConfirmed)
    #expect(observation.callbackCount>=2 && observation.packetCount>=2)
    #expect(observation.cleanupConfirmed)
    await #expect(throws:NativeMIDIPlayback.Failure.self) { _=try await player.run() }
    try player.close()
    #expect(throws:NativeMIDIMonitor.Failure.self) {
        _=try NativeMIDIMonitor.resolve(name:player.sourceName)
    }
}

@Test(.enabled(if:ProcessInfo.processInfo.environment["TIHULU_NATIVE_OBSERVER_FIXTURE"] == "1" &&
                  ProcessInfo.processInfo.environment["CI"] == "true"))
@MainActor func nativePlaybackStopBeforeRunEmitsNothing() async throws {
    let player=try NativeMIDIPlayback(clip:nativePlaybackClip())
    try player.open()
    defer { _=try? player.close() }
    player.requestStop()
    var task:Task<NativeMIDIPlayback.Report,Error>?
    let observation=try await NativeMIDIMonitor.observe(sourceName:player.sourceName,seconds:1,onConnected:{
        task=Task { @MainActor in try await player.run() }
    })
    let running=try #require(task)
    let report=try await running.value
    #expect(report.state=="stopped" && report.cancelled && report.cleanupConfirmed)
    #expect(observation.callbackCount==0 && observation.packetCount==0)
    try player.close()
}
#endif
