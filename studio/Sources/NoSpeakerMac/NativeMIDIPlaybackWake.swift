#if os(macOS)
import Foundation
import Dispatch

/// One-shot absolute-uptime wake. The timer never touches MIDI or actor
/// state. A lock arbitrates cancellation, installation and timer firing.
final class NativeMIDIPlaybackWake: @unchecked Sendable {
    private static let queue=DispatchQueue(label:"TIHULU.native-playback-wake",qos:.userInitiated)
    private let lock=NSLock()
    private var finished=false
    private var continuation:CheckedContinuation<UInt64,Error>?
    private var timer:(any DispatchSourceTimer)?

    static func wait(until deadline:UInt64) async throws -> UInt64 {
        let wake=NativeMIDIPlaybackWake()
        let fired=try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                wake.install(deadline:deadline,continuation:continuation)
            }
        } onCancel: {
            wake.complete(.failure(CancellationError()))
        }
        try Task.checkCancellation()
        return fired
    }

    private func install(deadline:UInt64,continuation:CheckedContinuation<UInt64,Error>) {
        lock.lock()
        if finished {
            lock.unlock()
            continuation.resume(throwing:CancellationError())
            return
        }
        self.continuation=continuation
        let source=DispatchSource.makeTimerSource(flags:.strict,queue:Self.queue)
        timer=source
        source.schedule(deadline:DispatchTime(uptimeNanoseconds:deadline),leeway:.nanoseconds(0))
        source.setEventHandler { [weak self] in
            self?.complete(.success(DispatchTime.now().uptimeNanoseconds))
        }
        // Activate before releasing the lock so cancellation cannot leave
        // a suspended source behind. Its callback waits for this lock.
        source.activate()
        lock.unlock()
    }

    private func complete(_ result:Result<UInt64,Error>) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished=true
        let pending=continuation
        let source=timer
        continuation=nil
        timer=nil
        lock.unlock()
        source?.cancel()
        pending?.resume(with:result)
    }
}
#endif
