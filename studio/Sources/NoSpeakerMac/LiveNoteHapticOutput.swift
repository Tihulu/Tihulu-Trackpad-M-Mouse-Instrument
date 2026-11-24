#if os(macOS)
import Foundation
import NoSpeakerCore

/// A reusable live-note output. Its private serial queue owns the timer and
/// frame. Stopping synchronously drains any in-flight actuation before return.
/// The host must reserve the shared actuator before creating this output.
public final class LiveNoteHapticOutput: @unchecked Sendable {
    private let driver: HapticTrackpadDriver
    private let queue = DispatchQueue(label: "com.tihulu.live-note-haptics", qos: .userInitiated)
    private var timer: DispatchSourceTimer?
    private var frame: HapticFrame?
    private var masterLevel = 0.75
    private var failure: (@Sendable (String) -> Void)?

    public init(driver: HapticTrackpadDriver) { self.driver = driver }

    public func start(onFailure: @escaping @Sendable (String) -> Void) {
        queue.sync {
            guard timer == nil else { return }
            failure = onFailure
            let source = DispatchSource.makeTimerSource(queue: queue)
            source.schedule(deadline: .now(), repeating: .milliseconds(18), leeway: .milliseconds(2))
            source.setEventHandler { [weak self] in self?.tick() }
            timer = source
            source.resume()
        }
    }

    public func update(frame: HapticFrame?, masterLevel: Double) {
        queue.sync {
            self.frame = frame
            self.masterLevel = masterLevel.isFinite ? min(1, max(0, masterLevel)) : 0
        }
    }

    public func stop() {
        queue.sync { clear() }
    }

    private func clear() {
        frame = nil
        timer?.cancel()
        timer = nil
        failure = nil
    }

    private func tick() {
        guard let frame else { return }
        do { try driver.play(frame, masterLevel: masterLevel) }
        catch {
            let handler = failure
            clear()
            handler?(error.localizedDescription)
        }
    }
}
#endif
