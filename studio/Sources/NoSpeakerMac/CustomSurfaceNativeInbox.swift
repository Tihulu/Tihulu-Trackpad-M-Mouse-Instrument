#if os(macOS)
import Foundation
import NoSpeakerCore

/// Per-run, per-surface bounded FIFO, attached to the existing shared
/// monitor. Never calls MIDI or dispatches actor tasks in the native callback.
public final class CustomSurfaceNativeInbox: @unchecked Sendable {
    private let lock = NSLock()
    private let surface: TouchSurfaceKind
    private let orientation: SurfaceOrientation
    private var notBefore: Int64
    private let diagnosticOnly: Bool
    private var evidence = CustomSurfaceCaptureEvidence()
    private var samples: [CustomSurfaceNativeFrame] = []
    private var faulted = false
    private var closed = false
    public init(surface: TouchSurfaceKind, orientation: SurfaceOrientation, notBefore: Int64,
                diagnosticOnly: Bool = false) {
        self.surface = surface; self.orientation = orientation; self.notBefore = notBefore
        self.diagnosticOnly = diagnosticOnly
    }
    public func submit(_ frame: SurfaceTouchFrame) {
        lock.lock(); defer { lock.unlock() }
        guard !closed, !faulted, frame.surface == surface else { return }
        // A previously admitted callback can still be completing while a
        // new subscription is attached. Never replay it into the new run.
        if let receipt = frame.acquisitionNS, receipt < notBefore { return }
        let sample = CustomSurfaceNativeFrame(frame: frame, orientation: orientation)
        evidence.observe(receipt: frame.acquisitionNS, rawCount: frame.rawNativeContactCount,
                         rawStates: frame.rawNativeStates, decodedCount: frame.contacts.count,
                         occupied: sample.map { !$0.contacts.isEmpty })
        // Diagnostics never publish contacts or admit MIDI, including after
        // an invalid frame. The ordinary live path still fails closed.
        guard !diagnosticOnly else { return }
        guard samples.count < 64, let sample else {
            faulted = true
            samples.removeAll()
            return
        }
        samples.append(sample)
    }
    /// Drop all provisional samples when the actual output and emergency
    /// admission are ready. Do not revive an already faulted or closed inbox.
    @discardableResult
    public func begin(at receipt: Int64) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !closed, !faulted, receipt >= notBefore else { return false }
        notBefore = receipt
        evidence = .init()
        samples.removeAll(keepingCapacity: true)
        return true
    }
    /// A producer-side fault may arrive while the consumer is delivering
    /// an older drained batch. Check this gate before every live send.
    public var admitsDelivery: Bool {
        lock.lock(); defer { lock.unlock() }
        return !diagnosticOnly && !closed && !faulted
    }
    public func captureEvidence() -> CustomSurfaceCaptureEvidence {
        lock.lock(); defer { lock.unlock() }
        return evidence
    }
    public func drain() -> (samples: [CustomSurfaceNativeFrame], faulted: Bool) {
        lock.lock(); defer { lock.unlock() }
        let result = (samples, faulted)
        samples.removeAll(keepingCapacity: true)
        return result
    }
    public func close(at now: Int64? = nil) {
        lock.lock(); defer { lock.unlock() }
        guard !closed else { return }
        if let now { evidence.finish(at: now) }
        closed = true
        samples.removeAll()
    }
}
#endif
