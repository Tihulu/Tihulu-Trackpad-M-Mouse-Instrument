#if os(macOS)
import Foundation
import CoreMIDI
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
// Private fixture receives only its own newly created source. No raw
// MIDI messages are exposed by the public diagnostic interface.
private final class PlaybackFixtureTrace: @unchecked Sendable {
    struct Sample: Sendable {
        let word:UInt32
        let time:UInt64
    }
    private let lock=NSLock()
    private var samples:[Sample]=[]
    func record(_ word:UInt32) {
        lock.lock();defer { lock.unlock() }
        if samples.count<16 { samples.append(.init(word:word,time:DispatchTime.now().uptimeNanoseconds)) }
    }
    func snapshot()->[Sample] {
        lock.lock();defer { lock.unlock() }
        return samples
    }
}

private func makePlaybackFixtureClient(_ client:inout MIDIClientRef)->OSStatus {
    MIDIClientCreateWithBlock("TIHULU playback timing fixture" as CFString,&client) { @Sendable _ in }
}

private func makePlaybackFixturePort(_ client:MIDIClientRef,_ port:inout MIDIPortRef,
                                     trace:PlaybackFixtureTrace)->OSStatus {
    MIDIInputPortCreateWithProtocol(client,"TIHULU timing input" as CFString,._1_0,&port) { @Sendable list,_ in
        // A fixture sends one MIDI 1.0 channel-voice word per event,
        // separated in time. Unexpected batching fails the count checks.
        if list.pointee.numPackets==1 && list.pointee.packet.wordCount==1 {
            trace.record(list.pointee.packet.words.0)
        }
    }
}

@Test(.enabled(if:ProcessInfo.processInfo.environment["TIHULU_NATIVE_OBSERVER_FIXTURE"] == "1" &&
                  ProcessInfo.processInfo.environment["CI"] == "true"))
@MainActor func nativePlaybackReceiverVerifiesNoteGateAndCancellation() async throws {
    // Test normal playback and cancellation with distinct source identities.
    // Keep the receiving client alive across both sessions.
    var client=MIDIClientRef()
    try #require(makePlaybackFixtureClient(&client)==noErr && client != 0)
    defer { _=MIDIClientDispose(client) }
    for cancel in [false,true] {
        let clip=MIDIClip(bpm:120,length:3840,notes:[.init(start:0,duration:cancel ? 2880 : 480,channel:2,pitch:61,velocity:96)])
        let player=try NativeMIDIPlayback(clip:clip)
        try player.open()
        defer { _=try? player.close() }
        let source=try NativeMIDIMonitor.resolve(name:player.sourceName)
        let trace=PlaybackFixtureTrace()
        var port=MIDIPortRef()
        try #require(makePlaybackFixturePort(client,&port,trace:trace)==noErr && port != 0)
        defer { _=MIDIPortDispose(port) }
        try #require(MIDIPortConnectSource(port,source,nil)==noErr)
        defer { _=MIDIPortDisconnectSource(port,source) }
        let running=Task { @MainActor in try await player.run() }
        if cancel {
            // Wait for the actual receiver onset, not an arbitrary start delay.
            let deadline=ContinuousClock.now.advanced(by:.seconds(1))
            while trace.snapshot().isEmpty && ContinuousClock.now<deadline {
                try await Task.sleep(nanoseconds:5_000_000)
            }
            running.cancel()
        }
        let report=try await running.value
        let deadline=ContinuousClock.now.advanced(by:.milliseconds(250))
        while trace.snapshot().count<2 && ContinuousClock.now<deadline {
            try await Task.sleep(nanoseconds:5_000_000)
        }
        let rows=trace.snapshot()
        try #require(rows.count==2)
        // MIDI 1.0 UMP: type/group, status/channel, note, velocity.
        #expect(rows[0].word & 0xF0FFFFFF == 0x20923D60)
        #expect(rows[1].word & 0xF0FFFFFF == 0x20823D00)
        try #require(rows[1].time>=rows[0].time)
        let gate=rows[1].time-rows[0].time
        if cancel {
            #expect(report.cancelled)
            #expect(report.state=="stopped" || report.state=="faulted")
            #expect(gate<1_000_000_000)
            let retry=try player.retryCleanup()
            #expect(retry.cancelled && retry.cleanupConfirmed)
        } else {
            #expect(report.state=="finished" && !report.cancelled)
            // Deliberately broad hosted-runner tolerance, not physical latency.
            #expect((180_000_000...350_000_000).contains(gate))
        }
        #expect(report.cleanupConfirmed && report.outstandingNotes==0)
        #expect(!report.receiverConfirmed)
        try player.close()
    }
}
#endif
