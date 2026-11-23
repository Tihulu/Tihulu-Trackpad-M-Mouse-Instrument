#if os(macOS)
import Foundation
import NoSpeakerCore

public final class HapticPlaybackEngine: @unchecked Sendable {
    private let driver: HapticTrackpadDriver
    private let lock = NSLock()
    private var generation: UInt64 = 0
    private var worker: Task<Void, Never>?

    public init(driver: HapticTrackpadDriver) {
        self.driver = driver
    }

    public func play(events: [ScheduledHapticEvent], masterLevel: Double = 1, loop: Bool = false) {
        stop(closeDriver: false)
        lock.lock()
        generation &+= 1
        let token = generation
        lock.unlock()
        let sorted = events.sorted { $0.time < $1.time }
        guard !sorted.isEmpty else { return }

        worker = Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            repeat {
                let clock = ContinuousClock()
                let start = clock.now
                for event in sorted {
                    if Task.isCancelled || !self.isCurrent(token) { return }
                    let deadline = start.advanced(by: .nanoseconds(Int64(event.time * 1_000_000_000)))
                    try? await clock.sleep(until: deadline)
                    if Task.isCancelled || !self.isCurrent(token) { return }
                    try? self.driver.play(event.frame, masterLevel: masterLevel)
                }
            } while loop && !Task.isCancelled && self.isCurrent(token)
        }
    }

    public func play(frame: HapticFrame, masterLevel: Double = 1) {
        stop(closeDriver: false)
        worker = Task.detached(priority: .userInitiated) { [driver] in
            try? driver.play(frame, masterLevel: masterLevel)
        }
    }

    public func stop(closeDriver: Bool = false) {
        lock.lock()
        generation &+= 1
        lock.unlock()
        worker?.cancel()
        worker = nil
        if closeDriver { driver.panicStop() }
    }

    private func isCurrent(_ token: UInt64) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return generation == token
    }
}
#endif
