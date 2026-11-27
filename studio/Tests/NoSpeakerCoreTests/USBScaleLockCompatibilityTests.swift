import Foundation
import Testing
@testable import NoSpeakerCore

@Test func calibratedLegacyMapLeavesExplicitOriginalLaneAtCenterBend() throws {
    var scale = CustomScale()
    scale.intervals = [0, 2, 4, 7, 9]
    scale.centOffsets = [2: -25]
    let locked = try #require(PhysicalKeyboardScaleMap.legacy(scale, inputRoot: 60, outputRoot: 69, referenceA4: 432))
    let unlocked = try #require(PhysicalKeyboardScaleMap.legacy(scale, inputRoot: 60, outputRoot: 69, referenceA4: 432, allowOutsideScale: true))
    guard case .tuned(let calibrated) = unlocked.memberOutput(60) else {
        Issue.record("Expected calibrated tuned member"); return
    }
    #expect(calibrated.anchor == 69 && calibrated.bend < 8192)
    #expect(unlocked.memberOutput(60) == locked.memberOutput(60))
    #expect(unlocked.memberOutput(62) == locked.memberOutput(62))
    #expect(locked.memberOutput(61) == .muted)
    #expect(unlocked.memberOutput(61) == .original(inputNote: 61, anchor: 61, bend: 8192, bendRangeSemitones: 2))
    #expect(unlocked.memberOutput(61, bendRangeSemitones: 48) == .original(inputNote: 61, anchor: 61, bend: 8192, bendRangeSemitones: 48))
    #expect(unlocked.memberOutput(61, bendRangeSemitones: 97) == .unavailable)
}

@Test func usbScaleLockRetriesOnlyOutstandingNotesAndSustain() throws {
    var lock = try #require(PhysicalKeyboardScaleLock(intervals: [0, 2, 4, 7, 9], root: 60, channel: 5, allowOutsideScale: true))
    let mappedOff = SensorCommand(.init(.note, channel: 5, number: 60), value: 0)
    let originalOff = SensorCommand(.init(.note, channel: 5, number: 61), value: 0)
    let pedalOff = SensorCommand(.init(.sustain, channel: 5), value: 0)
    let a = lock.note(60, velocity: 90, send: { _ in true })
    let b = lock.note(61, velocity: 100, send: { _ in true })
    let c = lock.sustain(127, send: { _ in true })
    #expect(a == .delivered && b == .delivered && c == .delivered)
    var sent: [SensorCommand] = []
    let first = lock.stop { command in
        sent.append(command)
        return command == mappedOff
    }
    #expect(!first && lock.pendingCleanup)
    #expect(sent == [mappedOff, originalOff, pedalOff])
    sent.removeAll()
    let second = lock.stop { command in sent.append(command); return true }
    #expect(second && !lock.pendingCleanup)
    #expect(sent == [originalOff, pedalOff])
    sent.removeAll()
    let third = lock.stop { command in sent.append(command); return true }
    #expect(third && sent.isEmpty)
    let retired = lock.note(61, velocity: 90, send: { _ in true })
    #expect(retired == .retired)
}

@Test func usbScaleLockAmbiguousPedalReleaseRetainsOnlyPedalDebt() throws {
    var lock = try #require(PhysicalKeyboardScaleLock(intervals: [0, 2, 4, 7, 9], root: 60))
    let down = lock.sustain(64, send: { _ in true })
    #expect(down == .delivered)
    var sent: [SensorCommand] = []
    let failed = lock.sustain(63) { command in sent.append(command); return false }
    #expect(failed == .failed && lock.pendingCleanup && lock.retired)
    let pedalOff = SensorCommand(.init(.sustain), value: 0)
    #expect(sent == [pedalOff, pedalOff])
    sent.removeAll()
    let retry = lock.stop { command in sent.append(command); return true }
    #expect(retry && !lock.pendingCleanup && sent == [pedalOff])
}
