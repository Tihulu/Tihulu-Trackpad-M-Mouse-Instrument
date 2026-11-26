#if os(macOS)
import Foundation
import NoSpeakerCore

/// Independent publication gate; never held across an actuator call.
final class LiveHapticPublicationGate: @unchecked Sendable {
    private let lock=NSLock()
    private var open=false
    var permits:Bool {
        lock.lock(); defer { lock.unlock() }
        return open
    }
    func set(_ value:Bool) {
        lock.lock(); defer { lock.unlock() }
        open=value
    }
}

/// A reusable live-note output. Its private serial queue owns the timer and
/// frame. Stopping synchronously drains any in-flight actuation before return.
/// The host must reserve the shared actuator before creating this output.
public final class LiveNoteHapticOutput: @unchecked Sendable {
    private let driver: HapticTrackpadDriver
    private let shared: SharedLiveNoteOutput?
    private let sourceKind: HapticMixSource
    private let requiresFreshGroupFrames:Bool
    private let groupMailboxLock = NSLock()
    private var groupMailbox:GroupHapticMailbox?
    private enum StartError:Error { case incompatibleSharedOutput }
    private var lease: HapticMixLease?
    private let publicationGate=LiveHapticPublicationGate()
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
                groupMailboxLock.lock()
                groupMailbox = .init(now:ProcessInfo.processInfo.systemUptime)
                groupMailboxLock.unlock()
            }
            publicationGate.set(true)
            if let shared {
                do {
                    let gate=publicationGate
                    lease=try shared.begin(sourceKind,admitted:{ gate.permits },onFailure:onFailure)
                } catch {
                    publicationGate.set(false)
                    throw error
                }
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
        if requiresFreshGroupFrames {
            // Do not wait for the actuator queue or execute driver calls
            // under this lock. The consumer checks freshness itself.
            let now = ProcessInfo.processInfo.systemUptime
            groupMailboxLock.lock()
            _ = groupMailbox?.publish(frame:frame,masterLevel:masterLevel,now:now)
            groupMailboxLock.unlock()
            return
        }
        queue.sync {
            guard publicationGate.permits else { return }
            if let shared, let lease {
                shared.update(lease, frame: frame, level: masterLevel,
                              attack: attack, discardPendingAttacks: discardPendingAttacks)
                return
            }
            guard timer != nil else { return }
            self.masterLevel = masterLevel.isFinite ? min(1, max(0, masterLevel)) : 0
            if discardPendingAttacks || self.masterLevel == 0 { attacks.removeAll() }
            self.frame = frame
            if !requiresFreshGroupFrames,attack, self.masterLevel > 0, let frame, frame.level > 0 {
                attacks.offer(frame, now: ProcessInfo.processInfo.systemUptime)
            }
        }
    }

    public func updateGroup(snapshot:GroupHapticSnapshot,masterLevel:Double) {
        guard requiresFreshGroupFrames else { return }
        groupMailboxLock.lock()
        _ = groupMailbox?.publish(snapshot:snapshot,masterLevel:masterLevel,now:ProcessInfo.processInfo.systemUptime)
        groupMailboxLock.unlock()
    }

    /// Close the group mailbox without waiting for the driver. Global Stop
    /// can then release MIDI before draining the actuator queue.
    public func invalidateGroupFrames() { closeGroupMailbox() }

    /// Fence future rendering before synchronous MIDI cleanup. A slice
    /// already admitted to the driver may finish its bounded duration.
    public func invalidateFrames() {
        publicationGate.set(false)
        closeGroupMailbox()
    }

    public func stop() {
        invalidateFrames()
        queue.sync {
            if let shared, let lease { shared.release(lease) }
            lease = nil
            clear()
        }
    }

    private func closeGroupMailbox() {
        guard requiresFreshGroupFrames else { return }
        groupMailboxLock.lock()
        groupMailbox?.close()
        groupMailboxLock.unlock()
    }

    private func clear() {
        invalidateFrames()
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
        if requiresFreshGroupFrames {
            groupMailboxLock.lock()
            let sample = groupMailbox?.read(now:ProcessInfo.processInfo.systemUptime)
            let retired = groupMailbox?.retired ?? true
            groupMailboxLock.unlock()
            if retired { failFreshness(); return }
            guard let sample,let frame = sample.frame,sample.masterLevel > 0 else { return }
            do { try driver.play(frame,masterLevel:sample.masterLevel) }
            catch {
                let handler = failure
                clear()
                handler?(error.localizedDescription)
            }
            return
        }
        guard publicationGate.permits,masterLevel > 0,
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
