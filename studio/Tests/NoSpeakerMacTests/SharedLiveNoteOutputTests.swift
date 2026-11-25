#if os(macOS)
import Foundation
import Testing
import NoSpeakerCore
@testable import NoSpeakerMac

private final class SharedNoteMockSink: @unchecked Sendable {
    private let lock = NSLock()
    private var frames: [HapticFrame] = []
    private var failures = 0
    private var fail = false
    enum Disconnected: Error { case device }
    func write(_ frame: HapticFrame) throws {
        lock.lock(); defer { lock.unlock() }
        if fail { throw Disconnected.device }
        frames.append(frame)
    }
    func disconnect() { lock.lock(); fail = true; lock.unlock() }
    func recordFailure() { lock.lock(); failures += 1; lock.unlock() }
    func read() -> ([HapticFrame], Int) {
        lock.lock(); defer { lock.unlock() }
        return (frames, failures)
    }
}

@Test func sharedLiveNoteHostRefreshesHeldNotesAndReleasesIndependently() throws {
    let sink = SharedNoteMockSink()
    let coordinator = HapticOutputCoordinator(clock: { 1 }, sink: { try sink.write($0) })
    let host = SharedLiveNoteOutput(coordinator: coordinator, automaticScheduling: false)
    let a = try host.begin(.chords) { _ in sink.recordFailure() }
    let b = try host.begin(.touchBar) { _ in sink.recordFailure() }
    let chord = NoteHapticRenderer.frame(notes: [60,64,67], velocity: 100)
    let lead = NoteHapticRenderer.frame(notes: [69], velocity: 100)
    host.update(a, frame: chord, level: 0.7)
    host.update(b, frame: lead, level: 0.7)
    host.renderOnce()
    #expect(sink.read().0.last?.tones.count == 4)
    host.release(a)
    host.renderOnce()
    #expect(sink.read().0.last?.tones == lead?.tones)
    host.update(b, frame: nil, level: 0)
    host.renderOnce()
    #expect(sink.read().0.count == 2)
    host.retire()
    host.update(b, frame: lead, level: 1)
    host.renderOnce()
    #expect(sink.read().0.count == 2)
    #expect(sink.read().1 == 0)
}

@Test func sharedLiveNoteHostDisarmsBothOnSinkFailure() throws {
    let sink = SharedNoteMockSink()
    let coordinator = HapticOutputCoordinator(clock: { 1 }, sink: { try sink.write($0) })
    let host = SharedLiveNoteOutput(coordinator: coordinator, automaticScheduling: false)
    let a = try host.begin(.chords) { _ in sink.recordFailure() }
    let b = try host.begin(.touchBar) { _ in sink.recordFailure() }
    let frame = NoteHapticRenderer.frame(notes: [60], velocity: 100)
    host.update(a, frame: frame, level: 1)
    host.update(b, frame: frame, level: 1)
    sink.disconnect()
    host.renderOnce()
    #expect(coordinator.isRetired)
    #expect(sink.read().1 == 2)
    host.renderOnce()
    #expect(sink.read().1 == 2)
    #expect(throws: HapticOutputCoordinatorError.retired) {
        try host.begin(.chords) { _ in sink.recordFailure() }
    }
}

@Test func sharedLiveNoteHostRejectsDuplicateAndUnsupportedSource() throws {
    let host = SharedLiveNoteOutput(coordinator: HapticOutputCoordinator { _ in }, automaticScheduling: false)
    let a = try host.begin(.chords) { _ in }
    #expect(throws: SharedLiveNoteError.self) { try host.begin(.chords) { _ in } }
    #expect(throws: SharedLiveNoteError.self) { try host.begin(.speech) { _ in } }
    host.release(a)
    _ = try host.begin(.chords) { _ in }
    host.retire()
}
@Test func sharedLiveNoteShortAttackRendersOnceAndReleaseAllCancels() throws {
    let sink = SharedNoteMockSink()
    let coordinator = HapticOutputCoordinator(clock:{ 1 },sink:{ try sink.write($0) })
    let host = SharedLiveNoteOutput(coordinator:coordinator,automaticScheduling:false,clock:{ 1 })
    let lease = try host.begin(.chords) { _ in sink.recordFailure() }
    let chord = try #require(NoteHapticRenderer.frame(notes:[60,64,67],velocity:100))
    host.update(lease,frame:chord,level:0.7,attack:true)
    host.update(lease,frame:nil,level:0.7)
    host.renderOnce()
    #expect(sink.read().0.count == 1)
    #expect(sink.read().0.last?.tones.count == 3)
    host.renderOnce()
    #expect(sink.read().0.count == 1)
    host.update(lease,frame:chord,level:0.7,attack:true)
    host.update(lease,frame:nil,level:0,discardPendingAttacks:true)
    host.renderOnce()
    #expect(sink.read().0.count == 1)
    host.update(lease,frame:chord,level:0.7,attack:true)
    host.release(lease)
    host.renderOnce()
    #expect(sink.read().0.count == 1)
    host.retire()
}
#endif
