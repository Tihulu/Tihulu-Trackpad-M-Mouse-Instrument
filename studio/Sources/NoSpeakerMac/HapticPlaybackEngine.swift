#if os(macOS)
import Foundation
import NoSpeakerCore

public final class HapticPlaybackEngine: @unchecked Sendable {
    private let driver: HapticTrackpadDriver
    private let lock = NSLock()
    private var generation: UInt64 = 0
    private var worker: Task<Void, Never>?

    public init(driver: HapticTrackpadDriver) { self.driver = driver }

    public func play(events: [ScheduledHapticEvent], masterLevel: Double = 1,
                     loop: Bool = false, duration: Double? = nil,
                     onCompletion: (@Sendable (String?) -> Void)? = nil) {
        let timeline = PlaybackTimeline(events: events, duration: duration, loop: loop)
        lock.lock()
        defer { lock.unlock() }
        generation &+= 1
        worker?.cancel()
        worker = nil
        guard timeline.canPlay else { onCompletion?(nil); return }
        let token = generation
        worker = Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            let clock = ContinuousClock()
            let period = Duration.nanoseconds(max(1, Int64(timeline.duration * 1_000_000_000)))
            var start = clock.now
            do {
                repeat {
                    for event in timeline.events {
                        guard !Task.isCancelled, self.isCurrent(token) else { return }
                        let deadline = start.advanced(by: .nanoseconds(Int64(event.time * 1_000_000_000)))
                        try await clock.sleep(until: deadline)
                        guard !Task.isCancelled, self.isCurrent(token) else { return }
                        var frame = event.frame
                        if loop { frame.durationMS = min(frame.durationMS, (timeline.duration - event.time) * 1000) }
                        guard frame.durationMS >= 0.5 else { continue }
                        let end = deadline.advanced(by: .nanoseconds(Int64(frame.durationMS * 1_000_000)))
                        guard clock.now < end else { continue }
                        if !(try self.playIfCurrent(frame, level: masterLevel, token: token)) { return }
                    }
                    let boundary = start.advanced(by: period)
                    try await clock.sleep(until: boundary)
                    guard !Task.isCancelled, self.isCurrent(token) else { return }
                    start = clock.now >= boundary.advanced(by: period) ? clock.now : boundary
                } while loop
                self.finish(token, error: nil, completion: onCompletion)
            } catch is CancellationError {
                return
            } catch {
                self.finish(token, error: error.localizedDescription, completion: onCompletion)
            }
        }
    }

    public func play(frame: HapticFrame, masterLevel: Double = 1,
                     onCompletion: (@Sendable (String?) -> Void)? = nil) {
        play(events: [.init(time: 0, frame: frame)], masterLevel: masterLevel, onCompletion: onCompletion)
    }

    public func stop(closeDriver: Bool = false) {
        lock.lock()
        defer { lock.unlock() }
        generation &+= 1
        worker?.cancel()
        worker = nil
        if closeDriver { driver.panicStop() }
    }

    private func isCurrent(_ token: UInt64) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return generation == token
    }

    private func finish(_ token: UInt64, error: String?, completion: (@Sendable (String?) -> Void)?) {
        lock.lock()
        defer { lock.unlock() }
        guard generation == token else { return }
        worker = nil
        // Completion must dispatch to its owner, not reenter this engine.
        completion?(error)
    }

    private func playIfCurrent(_ frame: HapticFrame, level: Double, token: UInt64) throws -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard generation == token else { return false }
        try driver.play(frame, masterLevel: level)
        return true
    }
}
#endif
