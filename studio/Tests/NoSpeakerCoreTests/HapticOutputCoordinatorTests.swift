import Foundation
import Dispatch
import Testing
@testable import NoSpeakerCore

private final class ManualOutputClock: @unchecked Sendable {
    private let lock = NSLock()
    private var time = 1.0
    func read() -> Double {
        lock.lock(); defer { lock.unlock() }
        return time
    }
    func advance(_ seconds: Double) {
        lock.lock(); defer { lock.unlock() }
        time += seconds
    }
}

private final class MockHapticSink: @unchecked Sendable {
    private let lock = NSLock()
    private var frames: [HapticFrame] = []
    private var failing = false
    enum Failure: Error { case disconnected }
    func write(_ frame: HapticFrame) throws {
        lock.lock(); defer { lock.unlock() }
        if failing { throw Failure.disconnected }
        frames.append(frame)
    }
    func fail() {
        lock.lock(); defer { lock.unlock() }
        failing = true
    }
    func read() -> [HapticFrame] {
        lock.lock(); defer { lock.unlock() }
        return frames
    }
}

@Test func sharedOwnerCombinesRealChordAndTouchBarNoteRenderers() throws {
    let clock = ManualOutputClock()
    let sink = MockHapticSink()
    let output = HapticOutputCoordinator(clock: { clock.read() }, sink: { try sink.write($0) })
    let chords = try output.begin(.chords, priority: 10)
    let touchBar = try output.begin(.touchBar)
    var bank = ChordPadState()
    _ = bank.press(slot: 0, pad: .init(name: "C", notes: [60,64,67]), channel: 0, velocity: 90)
    var keys = TouchBarNoteState()
    _ = keys.key(60, owner: .screenPiano, pressed: true, channel: 0, velocity: 100)
    _ = keys.key(69, owner: .nativePiano, pressed: true, channel: 0, velocity: 100)
    #expect(output.submit(NoteHapticRenderer.frame(notes: bank.activeNotes, velocity: 90), from: chords))
    #expect(output.submit(keys.frame(velocity: 100), from: touchBar))
    #expect(try output.tick())
    let combined = try #require(sink.read().last)
    #expect(combined.tones.count == 4)
    #expect(combined == HapticSafetyPolicy().clamp(combined))
    #expect(output.release(chords))
    clock.advance(0.008)
    #expect(try output.tick())
    let remaining = try #require(sink.read().last)
    #expect(remaining.tones == keys.frame(velocity: 100)?.tones)
    #expect(output.release(touchBar))
    #expect(!(try output.tick()))
    #expect(sink.read().count == 2)
}

@Test func sharedOwnerRejectsStaleLeaseAndExpiredFrame() throws {
    let clock = ManualOutputClock()
    let sink = MockHapticSink()
    let output = HapticOutputCoordinator(clock: { clock.read() }, sink: { try sink.write($0) })
    let old = try output.begin(.chords)
    let next = try output.begin(.chords)
    let frame = try #require(NoteHapticRenderer.frame(notes: [60], velocity: 90))
    #expect(!output.submit(frame, from: old))
    #expect(!output.release(old))
    #expect(output.submit(frame, from: next))
    clock.advance(0.020)
    #expect(!(try output.tick()))
    #expect(sink.read().isEmpty)
    #expect(output.submit(frame, from: next))
    #expect(try output.tick())
    output.retire()
    #expect(!output.submit(frame, from: next))
    #expect(!(try output.tick()))
    #expect(throws: HapticOutputCoordinatorError.retired) { try output.begin(.touchBar) }
    #expect(output.sourceCount == 0)
    #expect(sink.read().count == 1)
}

@Test func sharedOwnerFailsClosedOnSinkError() throws {
    let clock = ManualOutputClock()
    let sink = MockHapticSink()
    let output = HapticOutputCoordinator(clock: { clock.read() }, sink: { try sink.write($0) })
    let a = try output.begin(.chords)
    let b = try output.begin(.touchBar)
    let frame = try #require(NoteHapticRenderer.frame(notes: [60], velocity: 90))
    #expect(output.submit(frame, from: a))
    #expect(output.submit(frame, from: b))
    sink.fail()
    #expect(throws: MockHapticSink.Failure.self) { try output.tick() }
    #expect(output.isRetired)
    #expect(output.sourceCount == 0)
    #expect(!output.submit(frame, from: b))
    #expect(!(try output.tick()))
    #expect(sink.read().isEmpty)
}

@Test func sharedOwnerRetirementDrainsInFlightSink() throws {
    let clock = ManualOutputClock()
    let entered = DispatchSemaphore(value: 0)
    let returnPermit = DispatchSemaphore(value: 0)
    let finished = DispatchSemaphore(value: 0)
    let retirement = DispatchSemaphore(value: 0)
    let output = HapticOutputCoordinator(clock: { clock.read() }, sink: { _ in
        entered.signal()
        _ = returnPermit.wait(timeout: .now() + 3)
    })
    let lease = try output.begin(.chords)
    let frame = try #require(NoteHapticRenderer.frame(notes: [60], velocity: 90))
    #expect(output.submit(frame, from: lease))
    DispatchQueue.global().async {
        _ = try? output.tick()
        finished.signal()
    }
    #expect(entered.wait(timeout: .now() + 2) == .success)
    DispatchQueue.global().async {
        output.retire()
        retirement.signal()
    }
    #expect(retirement.wait(timeout: .now() + .milliseconds(30)) == .timedOut)
    returnPermit.signal()
    #expect(finished.wait(timeout: .now() + 2) == .success)
    #expect(retirement.wait(timeout: .now() + 2) == .success)
    #expect(!output.submit(frame, from: lease))
    #expect(!(try output.tick()))
}

@Test func sharedOwnerIdleAndExplicitClearDoNotWrite() throws {
    let clock = ManualOutputClock()
    let sink = MockHapticSink()
    let output = HapticOutputCoordinator(clock: { clock.read() }, sink: { try sink.write($0) })
    #expect(!(try output.tick()))
    let lease = try output.begin(.touchBar)
    #expect(!(try output.tick()))
    let frame = try #require(NoteHapticRenderer.frame(notes: [60], velocity: 90))
    #expect(output.submit(frame, from: lease))
    #expect(output.submit(nil, from: lease))
    #expect(!(try output.tick()))
    #expect(sink.read().isEmpty)
}
