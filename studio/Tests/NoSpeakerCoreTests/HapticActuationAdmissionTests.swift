import Testing
@testable import NoSpeakerCore

private let normalActuation = HapticFrame(tones:[.init(frequencyHz:220,amplitude:0.5),
    .init(frequencyHz:440,amplitude:0.25)],durationMS:28,level:0.8)

@Test func nativeActuationAdmissionRejectsNonfiniteAndInvalidInputs() {
    #expect(HapticActuationAdmission.prepare(normalActuation,masterLevel:.nan) == .invalid)
    #expect(HapticActuationAdmission.prepare(normalActuation,masterLevel:1.1) == .invalid)
    var bad = normalActuation
    bad.durationMS = .infinity
    #expect(HapticActuationAdmission.prepare(bad,masterLevel:1) == .invalid)
    bad = normalActuation
    bad.tones[0].frequencyHz = .nan
    #expect(HapticActuationAdmission.prepare(bad,masterLevel:1) == .invalid)
    bad = normalActuation
    bad.tones[1].amplitude = -0.1
    #expect(HapticActuationAdmission.prepare(bad,masterLevel:1) == .invalid)
}

@Test func nativeActuationAdmissionCannotRelaxPhysicalLimits() {
    #expect(HapticActuationAdmission.prepare(normalActuation,masterLevel:1,
        safety:.init(maxTonesPerFrame:7)) == .invalid)
    #expect(HapticActuationAdmission.prepare(normalActuation,masterLevel:1,
        safety:.init(maxFrequencyHz:5000)) == .invalid)
    #expect(HapticActuationAdmission.prepare(normalActuation,masterLevel:1,
        safety:.init(maxFrameDurationMS:121)) == .invalid)
    #expect(HapticActuationAdmission.prepare(normalActuation,masterLevel:1,
        safety:.init(minFrequencyHz:4000)) == .invalid)
}

@Test func nativeActuationAdmissionNormalizesAndClampsWithinStricterSafety() {
    let result = HapticActuationAdmission.prepare(normalActuation,masterLevel:0.5,
        safety:.init(maxLevel:0.6,maxFrameDurationMS:20))
    guard case let .frame(frame) = result else { Issue.record("Expected bounded frame"); return }
    #expect(frame.durationMS == 20 && frame.level == 0.3)
    #expect(abs(frame.tones[0].amplitude-2.0/3.0) < 0.000001)
    #expect(abs(frame.tones[1].amplitude-1.0/3.0) < 0.000001)
}

@Test func nativeActuationAdmissionSilenceNeverCreatesWaveform() {
    #expect(HapticActuationAdmission.prepare(normalActuation,masterLevel:0) == .silent)
    var silent = normalActuation
    silent.tones = [.init(frequencyHz:220,amplitude:0)]
    #expect(HapticActuationAdmission.prepare(silent,masterLevel:1) == .silent)
    silent.tones = []
    #expect(HapticActuationAdmission.prepare(silent,masterLevel:1) == .silent)
}

@Test func hapticFailureGateLatchesOnlyConsecutiveFailuresUntilExplicitReset() {
    var gate = HapticConsecutiveFailureGate()
    let first = gate.recordFailure()
    let second = gate.recordFailure()
    gate.recordSuccess()
    #expect(!first && !second && gate.consecutive == 0 && !gate.retired)
    let a = gate.recordFailure()
    let b = gate.recordFailure()
    let c = gate.recordFailure()
    let d = gate.recordFailure()
    gate.recordSuccess()
    #expect(!a && !b && c && !d && gate.retired && gate.consecutive == 3)
    gate.reset()
    #expect(!gate.retired && gate.consecutive == 0)
}
