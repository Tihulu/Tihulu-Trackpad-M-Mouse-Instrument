#if os(macOS)
import Foundation
import NoSpeakerCore

/// A reusable live-note output. Its private serial queue owns the timer and
/// frame. Stopping synchronously drains any in-flight actuation before return.
/// The host must reserve the shared actuator before creating this output.
public final class LiveNoteHapticOutput: @unchecked Sendable {
    private let driver: HapticTrackpadDriver
    private let shared: SharedLiveNoteOutput?
    private let sourceKind: HapticMixSource
    private let requiresFreshGroupFrames:Bool
    private var freshness = GroupHapticFreshness()
    private enum StartError:Error { case incompatibleSharedOutput }
    private var lease: HapticMixLease?
    private let queue = DispatchQueue(label: "com.tihulu.live-note-haptics", qos: .userInitiated)
    private var timer: DispatchSourceTimer?
    private var frame: HapticFrame?
    private var attacks = HapticAttackBuffer<HapticFrame>()
    private var masterLevel = 0.75
    private var failure: (@Sendable (String) -> Void)?

    public init(driver: HapticTrackpadDriver, shared: SharedLiveNoteOutput? = nil,
                sourceKind: HapticMixSource = .chords, requiresFreshGroupFrames:Bool = false) {
        self.driver = driver
        self.shared = shared
        self.sourceKind = sourceKind
        self.requiresFreshGroupFrames = requiresFreshGroupFrames
    }

    public func start(onFailure: @escaping @Sendable (String) -> Void) throws {
        try queue.sync {
            guard timer == nil, lease == nil else { return }
            if requiresFreshGroupFrames {
                guard shared == nil else { throw StartError.incompatibleSharedOutput }
                freshness = .init()
                _ = freshness.refresh(now:ProcessInfo.processInfo.systemUptime)
            }
            if let shared {
                lease = try shared.begin(sourceKind, onFailure: onFailure)
                return
            }
            failure = onFailure
            let source = DispatchSource.makeTimerSource(queue: queue)
            source.schedule(deadline: .now(), repeating: .milliseconds(18), leeway: .milliseconds(2))
            source.setEventHandler { [weak self] in self?.tick() }
            timer = source
            source.resume()
        }
    }

    public func update(frame: HapticFrame?, masterLevel: Double,
                       attack: Bool = false, discardPendingAttacks: Bool = false) {
        queue.sync {
            if let shared, let lease {
                shared.update(lease, frame: frame, level: masterLevel,
                              attack: attack, discardPendingAttacks: discardPendingAttacks)
                return
            }
            guard timer != nil else { return }
            if requiresFreshGroupFrames && !freshness.refresh(now:ProcessInfo.processInfo.systemUptime) {
                failFreshness(); return
            }
            self.masterLevel = masterLevel.isFinite ? min(1, max(0, masterLevel)) : 0
            if discardPendingAttacks || self.masterLevel == 0 { attacks.removeAll() }
            self.frame = frame
            if !requiresFreshGroupFrames,attack, self.masterLevel > 0, let frame, frame.level > 0 {
                attacks.offer(frame, now: ProcessInfo.processInfo.systemUptime)
            }
        }
    }

    public func stop() {
        queue.sync {
            if let shared, let lease { shared.release(lease) }
            lease = nil
            clear()
        }
    }

    private func clear() {
        frame = nil
        attacks.removeAll()
        timer?.cancel()
        timer = nil
        failure = nil
    }

    private func failFreshness() {
        let handler = failure
        clear()
        handler?("Group haptic host heartbeat expired. MIDI remains independent; restart to enable haptics.")
    }

    private func tick() {
        if requiresFreshGroupFrames && !freshness.check(now:ProcessInfo.processInfo.systemUptime) {
            failFreshness(); return
        }
        guard masterLevel > 0,
              let frame = LiveHapticFrameSelection.select(held:frame,
                  attack:attacks.take(now:ProcessInfo.processInfo.systemUptime)) else { return }
        do { try driver.play(frame, masterLevel: masterLevel) }
        catch {
            let handler = failure
            clear()
            handler?(error.localizedDescription)
        }
    }
}
#endif
