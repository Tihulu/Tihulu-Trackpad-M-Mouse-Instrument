#if os(macOS)
import Foundation
import NoSpeakerCore

public final class HapticPlaybackEngine: @unchecked Sendable {
    private let driver: HapticTrackpadDriver
    private let lock = NSLock()
    private var generation: UInt64 = 0
    private var worker: Task<Void, Never>?

    public init(driver: HapticTrackpadDriver) { self.driver = driver }

    public func play(events: [ScheduledHapticEvent], masterLevel: Double = 1, loop: Bool = false) {
        let sorted = events.filter { $0.time.isFinite && $0.time >= 0 && $0.time < 1e8 }.sorted { $0.time < $1.time }
        lock.lock()
        defer { lock.unlock() }
        generation &+= 1
        worker?.cancel()
        worker = nil
        guard !sorted.isEmpty else { return }
        let token = generation
        worker = Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            repeat {
                let clock = ContinuousClock()
                let start = clock.now
                for event in sorted {
                    if Task.isCancelled || !self.isCurrent(token) { return }
                    let deadline = start.advanced(by: .nanoseconds(Int64(event.time * 1_000_000_000)))
                    do { try await clock.sleep(until: deadline) } catch { return }
                    if Task.isCancelled || !self.playIfCurrent(event.frame, level: masterLevel, token: token) { return }
                }
            } while loop && !Task.isCancelled && self.isCurrent(token)
        }
    }

    public func play(frame: HapticFrame, masterLevel: Double = 1) {
        lock.lock()
        defer { lock.unlock() }
        generation &+= 1
        worker?.cancel()
        let token = generation
        worker = Task.detached(priority: .userInitiated) { [weak self] in
            guard !Task.isCancelled else { return }
            _ = self?.playIfCurrent(frame, level: masterLevel, token: token)
        }
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

    private func playIfCurrent(_ frame: HapticFrame, level: Double, token: UInt64) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard generation == token else { return false }
        try? driver.play(frame, masterLevel: level)
        return true
    }
}
#endif
