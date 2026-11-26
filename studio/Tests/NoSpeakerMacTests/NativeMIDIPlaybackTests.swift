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
    #expect(report.state=="finished",
            "state=\(report.state), reason=\(report.faultReason ?? "none"), max lateness ns=\(report.maximumObservedLatenessNS), identity ns=\(report.maximumIdentityCheckNS), native send ns=\(report.maximumNativeSendNS), wake lateness ns=\(report.maximumWakeLatenessNS)")
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
        var connected=true
        defer { if connected { _=MIDIPortDisconnectSource(port,source) } }
        let running=Task { @MainActor in try await player.run() }
        if cancel {
            // Wait for the actual receiver onset, not an arbitrary start delay.
            let deadline=ContinuousClock().now.advanced(by:.seconds(1))
            while trace.snapshot().isEmpty && ContinuousClock().now<deadline {
                try await Task.sleep(nanoseconds:5_000_000)
            }
            running.cancel()
        }
        let report=try await running.value
        print("TIHULU_NATIVE_TIMING receiver cancel=\(cancel) state=\(report.state) fault=\(report.faultReason ?? "none") late_ns=\(report.maximumObservedLatenessNS) wake_ns=\(report.maximumWakeLatenessNS) identity_ns=\(report.maximumIdentityCheckNS) send_ns=\(report.maximumNativeSendNS)")
        let deadline=ContinuousClock().now.advanced(by:.milliseconds(250))
        while trace.snapshot().count<2 && ContinuousClock().now<deadline {
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
            #expect(report.state=="finished" && !report.cancelled,
                    "state=\(report.state), reason=\(report.faultReason ?? "none"), max lateness ns=\(report.maximumObservedLatenessNS), identity ns=\(report.maximumIdentityCheckNS), native send ns=\(report.maximumNativeSendNS), wake lateness ns=\(report.maximumWakeLatenessNS)")
            // Deliberately broad hosted-runner tolerance, not physical latency.
            #expect((180_000_000...350_000_000).contains(gate))
        }
        #expect(report.cleanupConfirmed && report.outstandingNotes==0)
        #expect(!report.receiverConfirmed)
        try #require(MIDIPortDisconnectSource(port,source)==noErr)
        connected=false
        try player.close()
    }
}
// Exercise a real identity mutation on a source created solely by this test.
// A restored name cannot reactivate the retired production session.
@Test(.enabled(if:ProcessInfo.processInfo.environment["TIHULU_NATIVE_OBSERVER_FIXTURE"] == "1" &&
                  ProcessInfo.processInfo.environment["CI"] == "true"))
@MainActor func nativePlaybackRejectsChangedAndRestoredSourceIdentity() async throws {
    let player=try NativeMIDIPlayback(clip:nativePlaybackClip())
    try player.open()
    let source=try NativeMIDIMonitor.resolve(name:player.sourceName)
    // Fixture owns this source. Production deliberately refuses to dispose
    // an identity it has retired; the test can clean up its own fixture.
    defer {
        _=MIDIEndpointDispose(source)
        MIDIProcessClient.shared.unregisterIsolatedSource(source)
    }
    let changed="TIHULU renamed fixture "+UUID().uuidString
    try #require(MIDIObjectSetStringProperty(source,kMIDIPropertyName,changed as CFString)==noErr)
    await #expect(throws:NativeMIDIPlayback.Failure.self) { _=try await player.run() }
    try #require(MIDIObjectSetStringProperty(source,kMIDIPropertyName,player.sourceName as CFString)==noErr)
    await #expect(throws:NativeMIDIPlayback.Failure.self) { _=try await player.run() }
    #expect(throws:NativeMIDIPlayback.Failure.self) { try player.close() }
}
@Test(.enabled(if:ProcessInfo.processInfo.environment["TIHULU_NATIVE_OBSERVER_FIXTURE"] == "1" &&
                  ProcessInfo.processInfo.environment["CI"] == "true"))
@MainActor func nativePlaybackDetectsIdentityLossDuringInitialRest() async throws {
    // Two seconds of initial silence; identity loss must be detected
    // before the first scheduled onset, not only at the next send.
    let clip=MIDIClip(bpm:120,length:5760,notes:[.init(start:3840,duration:480,channel:0,pitch:60,velocity:90)])
    let player=try NativeMIDIPlayback(clip:clip)
    #expect(!player.lifecycle.sourceOpen && !player.lifecycle.recoveryRequired)
    try player.open()
    let source=try NativeMIDIMonitor.resolve(name:player.sourceName)
    defer {
        _=MIDIEndpointDispose(source)
        MIDIProcessClient.shared.unregisterIsolatedSource(source)
    }
    let running=Task { @MainActor in try await player.run() }
    let deadline=ContinuousClock().now.advanced(by:.milliseconds(500))
    while !player.lifecycle.running && ContinuousClock().now<deadline {
        try await Task.sleep(nanoseconds:5_000_000)
    }
    try #require(player.lifecycle.running)
    let changed="TIHULU rest fixture "+UUID().uuidString
    try #require(MIDIObjectSetStringProperty(source,kMIDIPropertyName,changed as CFString)==noErr)
    let report=try await running.value
    #expect(report.state=="faulted" && report.outstandingNotes==0 && !report.cleanupConfirmed)
    #expect(player.lifecycle.identityRetired && player.lifecycle.recoveryRequired)
    #expect(!player.lifecycle.running && player.lifecycle.sourceOpen)
    #expect(throws:NativeMIDIPlayback.Failure.self) { try player.close() }
}
@Test(.enabled(if:ProcessInfo.processInfo.environment["TIHULU_NATIVE_OBSERVER_FIXTURE"] == "1" &&
                  ProcessInfo.processInfo.environment["CI"] == "true"))
@MainActor func nativePlaybackStopBeforeRunCannotMaskLostIdentity() async throws {
    let player=try NativeMIDIPlayback(clip:nativePlaybackClip())
    try player.open()
    let source=try NativeMIDIMonitor.resolve(name:player.sourceName)
    defer {
        _=MIDIEndpointDispose(source)
        MIDIProcessClient.shared.unregisterIsolatedSource(source)
    }
    player.requestStop()
    try #require(MIDIObjectSetStringProperty(source,kMIDIPropertyName,("TIHULU cancelled fixture "+UUID().uuidString) as CFString)==noErr)
    await #expect(throws:NativeMIDIPlayback.Failure.self) { _=try await player.run() }
    #expect(player.lifecycle.state=="faulted")
    #expect(player.lifecycle.identityRetired && player.lifecycle.recoveryRequired)
    #expect(player.lifecycle.outstandingNotes==0 && !player.lifecycle.running)
    #expect(throws:NativeMIDIPlayback.Failure.self) { _=try player.retryCleanup() }
    #expect(throws:NativeMIDIPlayback.Failure.self) { try player.close() }
}

@Test(.enabled(if:ProcessInfo.processInfo.environment["TIHULU_NATIVE_OBSERVER_FIXTURE"] == "1" &&
                  ProcessInfo.processInfo.environment["CI"] == "true"))
@MainActor func nativePlaybackEmptyLedgerRetryStillChecksIdentity() async throws {
    let player=try NativeMIDIPlayback(clip:nativePlaybackClip())
    try player.open()
    let source=try NativeMIDIMonitor.resolve(name:player.sourceName)
    defer {
        _=MIDIEndpointDispose(source)
        MIDIProcessClient.shared.unregisterIsolatedSource(source)
    }
    player.requestStop()
    let report=try await player.run()
    #expect(report.state=="stopped" && report.cleanupConfirmed)
    try #require(MIDIObjectSetStringProperty(source,kMIDIPropertyName,("TIHULU cleanup fixture "+UUID().uuidString) as CFString)==noErr)
    #expect(throws:NativeMIDIPlayback.Failure.self) { _=try player.retryCleanup() }
    #expect(player.lifecycle.identityRetired && player.lifecycle.recoveryRequired)
    #expect(player.lifecycle.state=="faulted")
    try #require(MIDIObjectSetStringProperty(source,kMIDIPropertyName,player.sourceName as CFString)==noErr)
    #expect(throws:NativeMIDIPlayback.Failure.self) { _=try player.retryCleanup() }
    #expect(throws:NativeMIDIPlayback.Failure.self) { try player.close() }
}
@Test(.enabled(if:ProcessInfo.processInfo.environment["TIHULU_NATIVE_OBSERVER_FIXTURE"] == "1" &&
                  ProcessInfo.processInfo.environment["CI"] == "true"))
@MainActor func nativePlaybackCloseRetiresTerminalStateAfterIdentityLoss() async throws {
    let player=try NativeMIDIPlayback(clip:nativePlaybackClip())
    try player.open()
    let source=try NativeMIDIMonitor.resolve(name:player.sourceName)
    defer {
        _=MIDIEndpointDispose(source)
        MIDIProcessClient.shared.unregisterIsolatedSource(source)
    }
    player.requestStop()
    let stopped=try await player.run()
    #expect(stopped.state=="stopped" && stopped.cleanupConfirmed)
    let replacement="TIHULU close identity fixture "+UUID().uuidString
    try #require(MIDIObjectSetStringProperty(source,kMIDIPropertyName,replacement as CFString)==noErr)
    #expect(throws:NativeMIDIPlayback.Failure.self) { try player.close() }
    #expect(player.lifecycle.state=="faulted" && player.lifecycle.identityRetired && player.lifecycle.recoveryRequired)
    #expect(player.lifecycle.sourceOpen && player.lifecycle.outstandingNotes==0)
    try #require(MIDIObjectSetStringProperty(source,kMIDIPropertyName,player.sourceName as CFString)==noErr)
    #expect(throws:NativeMIDIPlayback.Failure.self) { try player.close() }
}
@Test @MainActor func nativePlaybackPreparedScheduleRejectsPreviouslyStartedAndUnopenedSession() async throws {
    var schedule=try BoundedMIDIPlayback(clip:nativePlaybackClip())
    let fresh=try NativeMIDIPlayback(prepared:schedule)
    await #expect(throws:NativeMIDIPlayback.Failure.self) { _=try await fresh.runAndClose() }
    _=try schedule.begin(now:0)
    #expect(throws:NativeMIDIPlayback.Failure.self) { _=try NativeMIDIPlayback(prepared:schedule) }
    #expect(!fresh.lifecycle.sourceOpen)
}

@Test(.enabled(if:ProcessInfo.processInfo.environment["TIHULU_NATIVE_OBSERVER_FIXTURE"] == "1" &&
                  ProcessInfo.processInfo.environment["CI"] == "true"))
@MainActor func nativePlaybackRunAndCloseDisposesOnlyOwnSource() async throws {
    let schedule=try BoundedMIDIPlayback(clip:nativePlaybackClip())
    let player=try NativeMIDIPlayback(prepared:schedule)
    let sibling=try NativeMIDIPlayback(prepared:schedule)
    try player.open()
    defer { _=try? player.close() }
    try sibling.open()
    defer { _=try? sibling.close() }
    player.requestStop()
    let result=try await player.runAndClose()
    #expect(result.playback.state=="stopped" && result.playback.cancelled)
    #expect(result.sourceDisposed && !result.recoveryRequired && result.playback.cleanupConfirmed)
    #expect(!result.completed)
    #expect(!result.playback.receiverConfirmed && !player.lifecycle.sourceOpen)
    #expect(throws:NativeMIDIMonitor.Failure.self) { _=try NativeMIDIMonitor.resolve(name:player.sourceName) }
    #expect(sibling.lifecycle.sourceOpen && !sibling.lifecycle.recoveryRequired)
    _=try NativeMIDIMonitor.resolve(name:sibling.sourceName)
    await #expect(throws:NativeMIDIPlayback.Failure.self) { _=try await player.runAndClose() }
}

@Test(.enabled(if:ProcessInfo.processInfo.environment["TIHULU_NATIVE_OBSERVER_FIXTURE"] == "1" &&
                  ProcessInfo.processInfo.environment["CI"] == "true"))
@MainActor func nativePlaybackRunAndClosePreservesIdentityRecoveryOnFailure() async throws {
    let player=try NativeMIDIPlayback(clip:nativePlaybackClip())
    try player.open()
    let source=try NativeMIDIMonitor.resolve(name:player.sourceName)
    defer {
        _=MIDIEndpointDispose(source)
        MIDIProcessClient.shared.unregisterIsolatedSource(source)
    }
    let changed="TIHULU session fixture "+UUID().uuidString
    try #require(MIDIObjectSetStringProperty(source,kMIDIPropertyName,changed as CFString)==noErr)
    await #expect(throws:NativeMIDIPlayback.Failure.self) { _=try await player.runAndClose() }
    #expect(player.lifecycle.sourceOpen && player.lifecycle.identityRetired && player.lifecycle.recoveryRequired)
    #expect(player.lifecycle.state=="faulted")
    try #require(MIDIObjectSetStringProperty(source,kMIDIPropertyName,player.sourceName as CFString)==noErr)
    #expect(throws:NativeMIDIPlayback.Failure.self) { try player.close() }
}
@Test(.enabled(if:ProcessInfo.processInfo.environment["TIHULU_NATIVE_OBSERVER_FIXTURE"] == "1" &&
                  ProcessInfo.processInfo.environment["CI"] == "true"))
@MainActor func nativePlaybackPreparedSessionReceivesNoteGateBeforeDisposal() async throws {
    let player=try NativeMIDIPlayback(prepared:BoundedMIDIPlayback(clip:nativePlaybackClip()))
    try player.open()
    defer { _=try? player.close() }
    let source=try NativeMIDIMonitor.resolve(name:player.sourceName)
    var client=MIDIClientRef(),port=MIDIPortRef()
    try #require(makePlaybackFixtureClient(&client)==noErr && client != 0)
    defer { _=MIDIClientDispose(client) }
    let trace=PlaybackFixtureTrace()
    try #require(makePlaybackFixturePort(client,&port,trace:trace)==noErr && port != 0)
    defer { _=MIDIPortDispose(port) }
    try #require(MIDIPortConnectSource(port,source,nil)==noErr)
    let result=try await player.runAndClose()
    print("TIHULU_NATIVE_TIMING prepared state=\(result.playback.state) fault=\(result.playback.faultReason ?? "none") late_ns=\(result.playback.maximumObservedLatenessNS) wake_ns=\(result.playback.maximumWakeLatenessNS) identity_ns=\(result.playback.maximumIdentityCheckNS) send_ns=\(result.playback.maximumNativeSendNS)")
    #expect(result.completed && result.sourceDisposed && !result.recoveryRequired,
            "state=\(result.playback.state), reason=\(result.playback.faultReason ?? "none"), max lateness ns=\(result.playback.maximumObservedLatenessNS), identity ns=\(result.playback.maximumIdentityCheckNS), native send ns=\(result.playback.maximumNativeSendNS), wake lateness ns=\(result.playback.maximumWakeLatenessNS)")
    #expect(result.playback.state=="finished" && !result.playback.receiverConfirmed)
    #expect(result.playback.cleanupConfirmed && result.playback.outstandingNotes==0)
    let deadline=ContinuousClock().now.advanced(by:.milliseconds(250))
    while trace.snapshot().count<2 && ContinuousClock().now<deadline {
        try await Task.sleep(nanoseconds:5_000_000)
    }
    let rows=trace.snapshot()
    try #require(rows.count==2)
    #expect(rows[0].word & 0xF0FFFFFF == 0x20903C5A)
    #expect(rows[1].word & 0xF0FFFFFF == 0x20803C00)
    try #require(rows[1].time>=rows[0].time)
    #expect((180_000_000...350_000_000).contains(rows[1].time-rows[0].time))
    #expect(throws:NativeMIDIMonitor.Failure.self) { _=try NativeMIDIMonitor.resolve(name:player.sourceName) }
}
@Test(.enabled(if:ProcessInfo.processInfo.environment["TIHULU_NATIVE_OBSERVER_FIXTURE"] == "1" &&
                  ProcessInfo.processInfo.environment["CI"] == "true"))
@MainActor func nativePlaybackOpenQuarantinesUnverifiedSourceWithoutDisposal() async throws {
    let player=try NativeMIDIPlayback(clip:nativePlaybackClip())
    let changed="TIHULU unverified open fixture "+UUID().uuidString
    var created=MIDIEndpointRef()
    var renamed:OSStatus = -1
    defer {
        if created != 0 {
            _=MIDIEndpointDispose(created)
            MIDIProcessClient.shared.unregisterIsolatedSource(created)
        }
    }
    #expect(throws:NativeMIDIPlayback.Failure.self) {
        try player.open(onCreated:{ source in
            created=source
            renamed=MIDIObjectSetStringProperty(source,kMIDIPropertyName,changed as CFString)
        })
    }
    try #require(created != 0 && renamed==noErr)
    #expect(try NativeMIDIMonitor.resolve(name:changed)==created)
    #expect(MIDIProcessClient.shared.isIsolatedSource(created))
    #expect(player.lifecycle.state=="faulted" && player.lifecycle.sourceOpen)
    #expect(player.lifecycle.identityRetired && player.lifecycle.recoveryRequired)
    #expect(player.lifecycle.outstandingNotes==0)
    #expect(throws:NativeMIDIPlayback.Failure.self) { try player.open() }
    await #expect(throws:NativeMIDIPlayback.Failure.self) { _=try await player.run() }
    #expect(throws:NativeMIDIPlayback.Failure.self) { try player.close() }
    #expect(try NativeMIDIMonitor.resolve(name:changed)==created)
}
@Test(.enabled(if:ProcessInfo.processInfo.environment["TIHULU_NATIVE_OBSERVER_FIXTURE"] == "1" &&
                  ProcessInfo.processInfo.environment["CI"] == "true"))
@MainActor func nativePlaybackSourceCapacityReleasesOnlyVerifiedClosedSlots() throws {
    var players:[NativeMIDIPlayback]=[]
    defer { for player in players { if player.lifecycle.sourceOpen { try? player.close() } } }
    for _ in 0..<NativeMIDIPlayback.maximumOpenSources {
        let player=try NativeMIDIPlayback(clip:nativePlaybackClip())
        players.append(player)
        try player.open()
    }
    let extra=try NativeMIDIPlayback(clip:nativePlaybackClip())
    players.append(extra)
    #expect(throws:NativeMIDIPlayback.Failure.self) { try extra.open() }
    #expect(!extra.lifecycle.sourceOpen && extra.lifecycle.state=="ready")
    let first=try #require(players.first)
    try first.close()
    #expect(throws:NativeMIDIMonitor.Failure.self) { _=try NativeMIDIMonitor.resolve(name:first.sourceName) }
    try extra.open()
    #expect(extra.lifecycle.sourceOpen)
    for player in players.dropFirst() {
        #expect(try NativeMIDIMonitor.resolve(name:player.sourceName) != 0)
    }
    for player in players.dropFirst() { try player.close() }
    #expect(players.allSatisfy { !$0.lifecycle.sourceOpen })
}
#endif
