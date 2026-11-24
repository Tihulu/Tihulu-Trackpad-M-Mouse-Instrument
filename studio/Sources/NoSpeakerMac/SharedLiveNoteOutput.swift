#if os(macOS)
import Foundation
import NoSpeakerCore

/// Opt-in shared live-note path. One timer, one synchronous sink, at most two
/// armed sources. All held-note intents and timer callbacks are queue-confined.
/// Only the controller may reserve the driver against legacy producers.
public final class SharedLiveNoteOutput: @unchecked Sendable {
    private struct Input {
        let lease: HapticMixLease
        let failure: @Sendable (String) -> Void
        var frame: HapticFrame?
        var level: Double = 0
    }

    private let queue = DispatchQueue(label: "com.tihulu.shared-live-notes", qos: .userInitiated)
    private let coordinator: HapticOutputCoordinator
    private let automaticScheduling: Bool
    private var inputs: [HapticMixSource: Input] = [:]
    private var timer: DispatchSourceTimer?
    private var timerGeneration: UInt64 = 0

    public convenience init(driver: HapticTrackpadDriver) {
        self.init(coordinator: HapticOutputCoordinator { frame in
            try driver.play(frame)
        }, automaticScheduling: true)
    }

    // Deterministic sink injection for Mac integration tests; production uses
    // the same render path with a timer and the real driver.
    init(coordinator: HapticOutputCoordinator, automaticScheduling: Bool) {
        self.coordinator = coordinator
        self.automaticScheduling = automaticScheduling
    }

    public func begin(_ source: HapticMixSource,
                      onFailure: @escaping @Sendable (String) -> Void) throws -> HapticMixLease {
        try queue.sync {
            guard source == .chords || source == .touchBar else {
                throw SharedLiveNoteError.unsupportedSource
            }
            guard inputs[source] == nil else { throw SharedLiveNoteError.alreadyArmed }
            let lease = try coordinator.begin(source)
            inputs[source] = Input(lease: lease, failure: onFailure)
            return lease
        }
    }

    public func update(_ lease: HapticMixLease, frame: HapticFrame?, level: Double) {
        queue.sync {
            guard var input = inputs[lease.source], input.lease == lease else { return }
            let gain = level.isFinite ? min(1, max(0, level)) : 0
            let sounding = gain > 0 && (frame?.level ?? 0) > 0 ? frame : nil
            input.frame = sounding
            input.level = gain
            inputs[lease.source] = input
            if sounding == nil { _ = coordinator.submit(nil, from: lease) }
            reconcileTimer()
        }
    }

    public func release(_ lease: HapticMixLease) {
        queue.sync {
            guard inputs[lease.source]?.lease == lease else { return }
            inputs.removeValue(forKey: lease.source)
            _ = coordinator.release(lease)
            reconcileTimer()
        }
    }

    public func retire() {
        queue.sync {
            stopTimer()
            inputs.removeAll()
            coordinator.retire()
        }
    }

    /// Synchronous manual tick for the injected-clock test path.
    func renderOnce() {
        queue.sync { renderLocked() }
    }

    private func stopTimer() {
        timerGeneration &+= 1
        timer?.cancel()
        timer = nil
    }

    private func reconcileTimer() {
        let sounding = inputs.values.contains { $0.frame != nil }
        guard sounding else { stopTimer(); return }
        guard automaticScheduling, timer == nil else { return }
        timerGeneration &+= 1
        let generation = timerGeneration
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(12), leeway: .milliseconds(1))
        timer.setEventHandler { [weak self] in
            guard let self, self.timerGeneration == generation else { return }
            self.renderLocked()
        }
        self.timer = timer
        timer.resume()
    }

    private func renderLocked() {
        guard !coordinator.isRetired else { return }
        for input in inputs.values {
            if let frame = input.frame {
                guard coordinator.submit(frame, from: input.lease, masterLevel: input.level) else {
                    failLocked("Invalid or expired shared haptic source.")
                    return
                }
            }
        }
        do { try coordinator.tick(sliceMS: 18) }
        catch { failLocked(error.localizedDescription) }
    }

    private func failLocked(_ message: String) {
        let handlers = inputs.values.map(\.failure)
        stopTimer()
        inputs.removeAll()
        coordinator.retire()
        // Handlers must schedule back to their owner, never reenter this queue.
        for handler in handlers { handler(message) }
    }
}

public enum SharedLiveNoteError: LocalizedError {
    case unsupportedSource, alreadyArmed
    public var errorDescription: String? {
        switch self {
        case .unsupportedSource: "This source is not supported by experimental shared output."
        case .alreadyArmed: "This shared output source is already armed."
        }
    }
}
#endif
