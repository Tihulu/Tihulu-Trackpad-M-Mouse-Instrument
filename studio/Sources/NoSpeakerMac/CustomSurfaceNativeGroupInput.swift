#if os(macOS)
import Foundation
import NoSpeakerCore

/// Bounded native input subscription and serialized consumer for one group.
/// The owner installs all inboxes atomically, explicitly begins once after
/// output and emergency admission are ready, and drives drain on its actor.
/// No MIDI registration, capture or automatic rearm occurs here.
public final class CustomSurfaceNativeGroupInput: @unchecked Sendable {
    public enum DrainResult: Equatable, Sendable {
        case delivered(Int), revoked
    }
    public let inboxes: [CustomSurfaceNativeInbox]
    private let lock = NSLock()
    private var began = false
    private var closed = false
    public init?(surfaces: Set<TouchSurfaceKind>, orientation: SurfaceOrientation, notBefore: Int64) {
        guard !surfaces.isEmpty, surfaces.count <= 2, notBefore >= 0 else { return nil }
        inboxes = [TouchSurfaceKind.trackpad, .magicMouse].filter { surfaces.contains($0) }.map {
            CustomSurfaceNativeInbox(surface: $0, orientation: orientation, notBefore: notBefore)
        }
        guard inboxes.count == surfaces.count else { return nil }
    }
    public var admitsSetup: Bool {
        lock.lock(); defer { lock.unlock() }
        return !closed && inboxes.allSatisfy { $0.admitsDelivery }
    }
    public var admitsDelivery: Bool {
        lock.lock(); defer { lock.unlock() }
        return began && !closed && inboxes.allSatisfy { $0.admitsDelivery }
    }
    @discardableResult
    public func begin(at receipt: Int64) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !closed, !began else { return false }
        guard inboxes.allSatisfy({ $0.begin(at: receipt) }) else {
            closed = true
            for inbox in inboxes { inbox.close(at: receipt) }
            return false
        }
        began = true
        return true
    }
    /// The owner serializes drain/close. Merge by genuine receipt time, not
    /// by re-stamping cached contacts. No source can monopolize a whole
    /// drain ahead of older frames from the other source.
    public func drain(deliver: (CustomSurfaceNativeFrame) -> Bool) -> DrainResult {
        guard admitsDelivery else { close(); return .revoked }
        let batches = inboxes.map { $0.drain() }
        guard batches.allSatisfy({ !$0.faulted }) else { close(); return .revoked }
        let frames = batches.enumerated().flatMap { index, batch in
            batch.samples.map { (index, $0) }
        }.sorted {
            if $0.1.observedAt != $1.1.observedAt { return $0.1.observedAt < $1.1.observedAt }
            return $0.0 < $1.0
        }
        for (_, frame) in frames {
            guard admitsDelivery, deliver(frame), admitsDelivery else { close(); return .revoked }
        }
        return .delivered(frames.count)
    }
    public func close(at receipt: Int64? = nil) {
        lock.lock(); defer { lock.unlock() }
        guard !closed else { return }
        closed = true
        let stoppedAt = receipt ?? Int64(clamping: DispatchTime.now().uptimeNanoseconds)
        for inbox in inboxes { inbox.close(at: stoppedAt) }
    }
}
#endif
