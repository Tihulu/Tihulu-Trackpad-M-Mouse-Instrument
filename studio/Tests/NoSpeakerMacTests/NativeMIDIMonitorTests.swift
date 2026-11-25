#if os(macOS)
import Foundation
import CoreMIDI
import Testing
@testable import NoSpeakerMac

/// This test creates only a uniquely named virtual source on a disposable
/// CI runner. Never emits fixture traffic into a user's local MIDI graph.
private func makeObserverFixtureClient(_ client:inout MIDIClientRef)->OSStatus {
    MIDIClientCreateWithBlock("TIHULU CI observer fixture" as CFString,&client) { @Sendable _ in }
}

@Test(.enabled(if:ProcessInfo.processInfo.environment["TIHULU_NATIVE_OBSERVER_FIXTURE"] == "1" &&
                  ProcessInfo.processInfo.environment["CI"] == "true"))
@MainActor func nativeObserverReceivesIsolatedFixtureAndClosesItsPort() async throws {
    var client=MIDIClientRef()
    let status=makeObserverFixtureClient(&client)
    try #require(status==noErr && client != 0)
    defer { _ = MIDIClientDispose(client) }
    var source=MIDIEndpointRef()
    let name="TIHULU CI "+UUID().uuidString
    let created=MIDISourceCreate(client,name as CFString,&source)
    try #require(created==noErr && source != 0)
    defer { _ = MIDIEndpointDispose(source) }
    var display:Unmanaged<CFString>?
    let named=MIDIObjectGetStringProperty(source,kMIDIPropertyDisplayName,&display)
    try #require(named==noErr)
    let label=try #require(display).takeRetainedValue() as String
    let resolved=try NativeMIDIMonitor.resolve(name:label)
    #expect(resolved==source)
    print("Native observer fixture: source resolved; opening receive port")
    let report=try await NativeMIDIMonitor.observe(sourceName:label,seconds:1,onConnected:{
        print("Native observer fixture: connected; injecting isolated packet")
        // Channel pressure zero, only from the disposable virtual source.
        // No physical output or destination is opened.
        var list=MIDIPacketList()
        let packet=MIDIPacketListInit(&list)
        let bytes:[UInt8]=[0xD0,0]
        let added=bytes.withUnsafeBufferPointer { buffer in
            MIDIPacketListAdd(&list,MemoryLayout<MIDIPacketList>.size,packet,
                              0,buffer.count,buffer.baseAddress!) != nil
        }
        try #require(added)
        let sent=MIDIReceived(source,&list)
        try #require(sent==noErr)
    })
    print("Native observer fixture: first session closed")
    #expect(report.callbackCount>=1)
    #expect(report.packetCount>=1)
    #expect(report.sourceStillPresent && report.cleanupConfirmed)
    // Cancellation while connected must never return a successful report.
    let cancelled=Task { @MainActor in
        try await NativeMIDIMonitor.observe(sourceName:label,seconds:10,onConnected:{
            withUnsafeCurrentTask { $0?.cancel() }
        })
    }
    do {
        _ = try await cancelled.value
        Issue.record("Cancelled native observation unexpectedly succeeded")
    } catch is CancellationError {
        // Expected: no successful report from a cancelled session.
    }
    // A second idle session must not inherit the first session's counts.
    let next=try await NativeMIDIMonitor.observe(sourceName:label,seconds:1)
    #expect(next.callbackCount==0 && next.packetCount==0 && next.cleanupConfirmed)
}

@Test @MainActor func nativeObserverRejectsInvalidDurationBeforeInventoryAccess() async {
    await #expect(throws:NativeMIDIMonitor.Failure.self) {
        try await NativeMIDIMonitor.observe(sourceName:"",seconds:0)
    }
}

@Test @MainActor func nativeObserverCancellationPrecedesInventoryAccess() async {
    let cancelled=Task { @MainActor in
        withUnsafeCurrentTask { $0?.cancel() }
        return try await NativeMIDIMonitor.observe(sourceName:"",seconds:1)
    }
    do {
        _ = try await cancelled.value
        Issue.record("Cancelled native observation unexpectedly succeeded")
    } catch is CancellationError {
        // Expected before source resolution.
    } catch {
        Issue.record("Unexpected error: \(error)")
    }
}
@Test(.enabled(if:ProcessInfo.processInfo.environment["TIHULU_NATIVE_OBSERVER_FIXTURE"] == "1" &&
                  ProcessInfo.processInfo.environment["CI"] == "true"))
@MainActor func nativeObserverRefusesSuccessAfterIdentityLoss() async throws {
    var client=MIDIClientRef()
    try #require(makeObserverFixtureClient(&client)==noErr && client != 0)
    defer { _=MIDIClientDispose(client) }
    var source=MIDIEndpointRef()
    let name="TIHULU observer identity fixture "+UUID().uuidString
    try #require(MIDISourceCreate(client,name as CFString,&source)==noErr && source != 0)
    defer { _=MIDIEndpointDispose(source) }
    do {
        _=try await NativeMIDIMonitor.observe(sourceName:name,seconds:1,onConnected:{
            let renamed="TIHULU retired observer "+UUID().uuidString
            try #require(MIDIObjectSetStringProperty(source,kMIDIPropertyName,renamed as CFString)==noErr)
        })
        Issue.record("Observation returned success after original source identity changed")
    } catch NativeMIDIMonitor.Failure.sourceUnavailable {
        // Expected: ambiguous counts cannot be returned as success.
    }
    try #require(MIDIObjectSetStringProperty(source,kMIDIPropertyName,name as CFString)==noErr)
    let next=try await NativeMIDIMonitor.observe(sourceName:name,seconds:1)
    #expect(next.cleanupConfirmed && next.sourceStillPresent && next.callbackCount==0)
}
#endif
