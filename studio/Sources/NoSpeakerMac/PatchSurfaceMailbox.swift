#if os(macOS)
import Foundation
import NoSpeakerCore

/// Per-run bounded FIFO. No MainActor work or MIDI in the private callback.
/// Overflow is a hard fault, never a silently dropped release transition.
public final class PatchSurfaceMailbox: @unchecked Sendable {
    public struct Sample: Sendable {
        public let frame: SurfaceTouchFrame
        public let time: Double
    }
    private let lock = NSLock()
    private var samples: [Sample] = []
    private var overflow = false
    private var closed = false
    private let excludedSurface: TouchSurfaceKind?
    public init(excludedSurface:TouchSurfaceKind? = nil) { self.excludedSurface = excludedSurface }

    public func submit(_ frame: SurfaceTouchFrame) {
        lock.lock()
        defer { lock.unlock() }
        guard !closed, !overflow, frame.surface != excludedSurface else { return }
        guard samples.count < 64, frame.contacts.count <= NativeTouchFramePolicy.maximumContacts else {
            overflow = true
            samples.removeAll()
            return
        }
        samples.append(.init(frame: frame, time: ProcessInfo.processInfo.systemUptime))
    }

    public func drain() -> (samples: [Sample], overflow: Bool) {
        lock.lock()
        defer { lock.unlock() }
        let result = (samples, overflow)
        samples.removeAll(keepingCapacity: true)
        return result
    }

    public func close() {
        lock.lock()
        defer { lock.unlock() }
        closed = true
        samples.removeAll()
    }
}
#endif
