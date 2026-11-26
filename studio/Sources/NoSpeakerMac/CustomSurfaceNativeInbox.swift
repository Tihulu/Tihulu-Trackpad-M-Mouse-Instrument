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
    private var samples: [CustomSurfaceNativeFrame] = []
    private var faulted = false
    private var closed = false
    public init(surface: TouchSurfaceKind, orientation: SurfaceOrientation, notBefore: Int64) {
        self.surface = surface; self.orientation = orientation; self.notBefore = notBefore
    }
    public func submit(_ frame: SurfaceTouchFrame) {
        lock.lock(); defer { lock.unlock() }
        guard !closed, !faulted, frame.surface == surface else { return }
        // A previously admitted callback can still be completing while a
        // new subscription is attached. Never replay it into the new run.
        if let receipt = frame.acquisitionNS, receipt < notBefore { return }
        guard samples.count < 64, let sample = CustomSurfaceNativeFrame(frame: frame, orientation: orientation) else {
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
        samples.removeAll(keepingCapacity: true)
        return true
    }
    public func drain() -> (samples: [CustomSurfaceNativeFrame], faulted: Bool) {
        lock.lock(); defer { lock.unlock() }
        let result = (samples, faulted)
        samples.removeAll(keepingCapacity: true)
        return result
    }
    public func close() {
        lock.lock(); defer { lock.unlock() }
        closed = true
        samples.removeAll()
    }
}
#endif
