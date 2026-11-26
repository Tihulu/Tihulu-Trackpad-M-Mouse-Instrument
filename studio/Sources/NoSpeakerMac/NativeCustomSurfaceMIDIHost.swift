#if os(macOS)
import Foundation
import CoreMIDI
import NoSpeakerCore

/// Explicit, dedicated virtual sources only; never opens a physical MIDI
/// destination or a shared legacy port. The process singleton retains recovery
/// records. A source adapter must supply genuine complete contact snapshots
/// with receipt timestamps in the same monotonic domain as monotonicNow().
@MainActor
public final class NativeCustomSurfaceMIDIHost {
    public static let shared = NativeCustomSurfaceMIDIHost()
    public typealias Status = CustomSurfaceEndpointHost.Status
    private typealias Endpoint = CustomSurfaceEndpointHost.Endpoint
    private let host: CustomSurfaceEndpointHost
    private var watchdog: Task<Void, Never>?

    private init() {
        host = CustomSurfaceEndpointHost(backend: .init(
            create: { Self.create($0) },
            owns: { Self.matches($0) },
            send: { Self.send($0, bytes: $1) },
            dispose: { Self.dispose($0) }
        ))
    }
    public nonisolated static func monotonicNow() -> Int64 {
        Int64(clamping: DispatchTime.now().uptimeNanoseconds)
    }
    public var statuses: [Status] { host.statuses }

    /// No input capture or automatic rearm. Non-live returned states are
    /// recovery records, not successful activation.
    public func open(plan: CustomSurfaceMixedPlan, admitsLive: @escaping () -> Bool) -> Status? {
        let status = host.open(plan: plan, clock: { Self.monotonicNow() }, admitsLive: admitsLive)
        reconcileWatchdog()
        return status
    }
    public func frame(_ id: UUID, surface: CustomSurfacePadLayout.Surface,
                      contacts: [CustomSurfaceContactProjection.Contact],
                      sequence: UInt64, observedAt: Int64) -> Status? {
        let status = host.frame(id, surface: surface, contacts: contacts, sequence: sequence, observedAt: observedAt)
        reconcileWatchdog()
        return status
    }
    @discardableResult
    public func close(_ id: UUID) -> Status? {
        let status = host.close(id)
        reconcileWatchdog()
        return status
    }
    /// Explicit scoped cleanup, never a process-wide or DAW-wide panic.
    /// Failed recovery records remain available through statuses.
    public func closeAll() -> [Status] {
        let ids = host.statuses.map(\.id)
        let reports = ids.compactMap { host.close($0) }
        reconcileWatchdog()
        return reports
    }

    private func reconcileWatchdog() {
        guard host.statuses.contains(where: { $0.phase == .live }) else {
            watchdog?.cancel()
            watchdog = nil
            return
        }
        guard watchdog == nil else { return }
        // Main actor serialized with frame/close. A blocked main actor may
        // delay cleanup; per-send freshness fences still prevent late attacks.
        watchdog = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(25)) } catch { return }
                guard let self, !Task.isCancelled else { return }
                self.host.poll()
                if !self.host.statuses.contains(where: { $0.phase == .live }) {
                    self.watchdog = nil
                    return
                }
            }
        }
    }

    private static func create(_ name: String) -> CustomSurfaceEndpointHost.Creation? {
        guard let client = try? MIDIProcessClient.shared.acquire() else { return nil }
        var source = MIDIEndpointRef()
        let result = MIDISourceCreate(client, name as CFString, &source)
        guard source != 0 else { return nil }
        // Exclude even partially created handles from automatic legacy
        // input attachment. Do not unregister an uncertain handle.
        MIDIProcessClient.shared.registerIsolatedSource(source)
        var uid: Int32 = 0
        let identified = MIDIObjectGetIntegerProperty(source, kMIDIPropertyUniqueID, &uid)
        let endpoint = Endpoint(handle: source, uniqueID: uid, name: name)
        return .init(endpoint: endpoint, succeeded: result == noErr && identified == noErr && matches(endpoint))
    }
    private static func matches(_ endpoint: Endpoint) -> Bool {
        var actual: Int32 = 0
        guard endpoint.handle != 0, endpoint.uniqueID != 0,
              MIDIObjectGetIntegerProperty(endpoint.handle, kMIDIPropertyUniqueID, &actual) == noErr,
              actual == endpoint.uniqueID else { return false }
        var label: Unmanaged<CFString>?
        guard MIDIObjectGetStringProperty(endpoint.handle, kMIDIPropertyName, &label) == noErr,
              let label else { return false }
        return label.takeRetainedValue() as String == endpoint.name
    }
    private static func send(_ endpoint: Endpoint, bytes: [UInt8]) -> Bool {
        // Host has just checked original identity then per-send freshness.
        // Do not insert a second slow identity query before native delivery.
        guard endpoint.handle != 0, bytes.count == 3 else { return false }
        var list = MIDIPacketList()
        let packet = MIDIPacketListInit(&list)
        let added = bytes.withUnsafeBufferPointer { buffer in
            MIDIPacketListAdd(&list, MemoryLayout<MIDIPacketList>.size, packet,
                              0, buffer.count, buffer.baseAddress!) != nil
        }
        return added && MIDIReceived(endpoint.handle, &list) == noErr
    }
    private static func dispose(_ endpoint: Endpoint) -> Bool {
        // The host validates immediately before disposal. A failed native
        // call retains its record and next retry revalidates the identity.
        guard MIDIEndpointDispose(endpoint.handle) == noErr else { return false }
        MIDIProcessClient.shared.unregisterIsolatedSource(endpoint.handle)
        return true
    }
}
#endif
