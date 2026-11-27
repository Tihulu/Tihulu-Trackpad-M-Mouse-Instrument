#if os(macOS)
import Foundation
import NoSpeakerCore

/// Per-run, per-surface bounded FIFO, attached to the existing shared
/// monitor. Never calls MIDI or dispatches actor tasks in the native callback.
public final class CustomSurfaceNativeInbox: @unchecked Sendable {
    private let lock = NSLock()
    public let surface: TouchSurfaceKind
    private let orientation: SurfaceOrientation
    private var notBefore: Int64
    private let diagnosticOnly: Bool
    private var evidence = CustomSurfaceCaptureEvidence()
    private var samples: [CustomSurfaceNativeFrame] = []
    public enum Fault: String, Sendable {
        case invalidFrame = "Invalid or incomplete native contact frame"
        case overflow = "Native contact FIFO overflow"
        case registrationChanged = "Native surface registration changed or missing"
        case unorderedFrame = "Native contact sequence or receipt regressed"
    }
    private var fault: Fault?
    private var peakDepth = 0
    private var previousSequence: UInt64?
    private var previousReceipt: Int64?
    private var closed = false
    private var began = false
    private var expectedRegistration: UUID?
    public init(surface: TouchSurfaceKind, orientation: SurfaceOrientation, notBefore: Int64,
                diagnosticOnly: Bool = false) {
        self.surface = surface; self.orientation = orientation; self.notBefore = notBefore
        self.diagnosticOnly = diagnosticOnly
    }
    public func submit(_ frame: SurfaceTouchFrame) {
        lock.lock(); defer { lock.unlock() }
        guard !closed, fault == nil, frame.surface == surface else { return }
        // A previously admitted callback can still be completing while a
        // new subscription is attached. Never replay it into the new run.
        if let receipt = frame.acquisitionNS, receipt < notBefore { return }
        if let expectedRegistration, frame.nativeRegistration != expectedRegistration {
            latch(.registrationChanged); return
        }
        let sample = CustomSurfaceNativeFrame(frame: frame, orientation: orientation)
        evidence.observe(receipt: frame.acquisitionNS, rawCount: frame.rawNativeContactCount,
                         rawStates: frame.rawNativeStates, decodedCount: frame.contacts.count,
                         occupied: sample.map { !$0.contacts.isEmpty })
        // Diagnostics never publish contacts or admit MIDI, including after
        // an invalid frame. The ordinary live path still fails closed.
        guard !diagnosticOnly else { return }
        // Detect disorder on the producer side, even when the consumer
        // is still emitting a previously drained batch.
        guard let sample else { latch(.invalidFrame); return }
        guard previousSequence.map({ sample.sequence > $0 }) ?? true,
              previousReceipt.map({ sample.observedAt > $0 }) ?? true else {
            latch(.unorderedFrame); return
        }
        guard samples.count < 64 else { latch(.overflow); return }
        previousSequence = sample.sequence
        previousReceipt = sample.observedAt
        samples.append(sample)
        peakDepth = max(peakDepth, samples.count)
    }
    private func latch(_ reason: Fault) {
        fault = reason
        samples.removeAll()
    }
    /// Bind the registration selected by the driver, not by the first
    /// received frame. Only setup may bind, exactly once.
    @discardableResult
    public func bindRegistration(_ token: UUID) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !closed, !began, fault == nil, expectedRegistration == nil else { return false }
        expectedRegistration = token
        samples.removeAll(keepingCapacity: true)
        previousSequence = nil; previousReceipt = nil
        return true
    }
    /// Drop all provisional samples when the actual output and emergency
    /// admission are ready. Do not revive an already faulted or closed inbox.
    @discardableResult
    public func begin(at receipt: Int64) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !closed, !began, fault == nil, receipt >= notBefore else { return false }
        began = true
        notBefore = receipt
        evidence = .init()
        peakDepth = 0
        previousSequence = nil; previousReceipt = nil
        samples.removeAll(keepingCapacity: true)
        return true
    }
    /// A producer-side fault may arrive while the consumer is delivering
    /// an older drained batch. Check this gate before every live send.
    public var admitsDelivery: Bool {
        lock.lock(); defer { lock.unlock() }
        return !diagnosticOnly && !closed && fault == nil
    }
    public func captureEvidence() -> CustomSurfaceCaptureEvidence {
        lock.lock(); defer { lock.unlock() }
        return evidence
    }
    public func queueEvidence() -> (peak: Int, fault: Fault?) {
        lock.lock(); defer { lock.unlock() }
        return (peakDepth, fault)
    }
    public func drain() -> (samples: [CustomSurfaceNativeFrame], faulted: Bool) {
        lock.lock(); defer { lock.unlock() }
        let result = (samples, fault != nil)
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
