import Testing
@testable import NoSpeakerCore

private func hand(_ x: Double = 0.5, open: Bool = true) -> AirHandSample? {
    AirHandSample.debugSample(x: x, y: 0.7, aperture: open ? 0.6 : 0.1)
}

@Test func mobileBeamUsesRealDepthAndReacquiresAfterLoss() throws {
    var beam = try #require(MobileAirInstrument(mode: .depthControl, keys: 0, near: 0.25, far: 0.75))
    var t = 1.0
    func sample(_ depth: Double?, _ visible: Bool = true) -> MobileAirOutput {
        t += 0.06
        return beam.frame(hand: visible ? hand() : nil, depth: depth, at: t, now: t)
    }
    #expect(sample(0.5).level == nil)
    #expect(sample(0.5).level == 0.5)
    #expect(sample(0.25).level == 1)
    #expect(sample(0.75).level == 0)
    for invalid in [nil, .nan, .infinity, 2] as [Double?] {
        #expect(sample(invalid).level == nil)
        #expect(sample(0.5).level == nil)
        #expect(sample(0.5).level == 0.5)
    }
    #expect(sample(0.5, false).level == nil)
}

@Test func beamZonesUseOnlyMappedKeysAndResistBoundaryJitter() throws {
    var beam = try #require(MobileAirInstrument(mode: .depthKeys, keys: 0b10001, near: 0.25, far: 0.75))
    var t = 0.0
    func sample(_ meters: Double) -> Int {
        t += 0.05
        return beam.frame(hand: hand(), depth: meters, at: t, now: t).keys
    }
    #expect(sample(0.65) == 0)
    #expect(sample(0.65) == 1)
    #expect(sample(0.49) == 1)
    #expect(sample(0.42) == 16)
    #expect(sample(0.51) == 16)
    #expect(sample(0.9) == 0)
}

@Test func mobilePinchRequiresOpenAndHoldsChosenKeyAcrossMotion() throws {
    var keys = try #require(MobileAirInstrument(mode: .pinchKeys, keys: 0b10001))
    var t = 0.0
    func frame(_ h: AirHandSample?, age: Double = 0) -> Int {
        t += 0.06
        return keys.frame(hand: h, at: t, now: t+age).keys
    }
    #expect(frame(hand(0, open: false)) == 0)
    #expect(frame(hand(0, open: false)) == 0)
    #expect(frame(hand(1)) == 0)
    #expect(frame(hand(1, open: false)) == 16)
    #expect(frame(hand(0, open: false)) == 16)
    #expect(frame(hand(0, open: false), age: 0.16) == 0)
    #expect(frame(hand(0, open: false)) == 0)
    #expect(frame(hand(0, open: false)) == 0)
    #expect(frame(hand(0)) == 0)
    #expect(frame(hand(0, open: false)) == 1)
    #expect(frame(nil) == 0)
}

@Test func mobileChordProjectsOnlyCompleteAuthorizedShapes() throws {
    let mask = 1 | (1 << 4) | (1 << 7)
    var chords = try #require(MobileAirInstrument(mode: .chords, keys: mask))
    var t = 0.0
    func sample(_ n: Int, open: Bool = true) -> Int {
        t += 0.07
        return chords.frame(hand: hand(open: open), fingers: n, confidence: 1, at: t, now: t).keys
    }
    _ = sample(0); _ = sample(0)
    for _ in 0..<4 { _ = sample(1) }
    #expect(sample(1, open: false) == mask)
    #expect(sample(2, open: false) == 0)
    for _ in 0..<4 { _ = sample(2) }
    #expect(sample(2, open: false) == 0)
}

@Test func mobileStringsAndHelperModesGateFreshHands() throws {
    #expect(MobileAirInstrument(mode: .strings, keys: 3) == nil)
    var strings = try #require(MobileAirInstrument(mode: .strings, keys: 0b10101))
    _ = strings.frame(hand: hand(0.1), at: 0, now: 0)
    _ = strings.frame(hand: hand(0.1), at: 0.05, now: 0.05)
    let stroke = strings.frame(hand: hand(0.9), at: 0.1, now: 0.1)
    #expect(stroke.keys == 0b10101)
    let released = strings.frame(hand: nil, at: 0.14, now: 0.14)
    #expect(released.keys == 0)
    for mode in [MobileAirMode.horizontal,.vertical,.aperture,.speed] {
        var helper = try #require(MobileAirInstrument(mode: mode, keys: 0))
        let first = helper.frame(hand: hand(), at: 0, now: 0)
        let second = helper.frame(hand: hand(), at: 0.06, now: 0.06)
        let duplicate = helper.frame(hand: hand(), at: 0.06, now: 0.07)
        #expect(first.level == nil && second.level != nil && duplicate.level == nil)
    }
}

@Test func mobileLiDARUsesConfidentLocalConsensusAndCorrectPixelOrientation() throws {
    let near: (Float,UInt8) = (0.4,2), far: (Float,UInt8) = (2,1)
    let good = Array(repeating: near, count: 5) + Array(repeating: far, count: 4)
    let d = try #require(MobileSensorOrientation.palmDepth(good))
    #expect(abs(d-0.4) < 0.0001)
    #expect(MobileSensorOrientation.palmDepth(Array(good.dropFirst()) + [(.nan,2)]) == nil)
    #expect(MobileSensorOrientation.palmDepth(Array(repeating: (0.4,0), count: 9)) == nil)
    for (orientation, x, y) in [(MobileSensorOrientation.up,0.25,0.25),(.right,0.25,0.75),(.down,0.75,0.75),(.left,0.75,0.25)] {
        let p = try #require(orientation.depthPoint(x: 0.25, y: 0.75))
        #expect(p.x == x && p.y == y)
    }
}


@Test func mobileStringsExpireIndependentlyAtPulseDeadlineAndNeverReplayLateCrossing() throws {
    var p = try #require(MobileAirInstrument(mode:.strings,keys:7))
    _ = p.frame(hand:hand(0.1),at:0,now:0)
    _ = p.frame(hand:hand(0.1),at:0.05,now:0.05)
    #expect(p.frame(hand:hand(0.9),at:0.1,now:0.1).keys == 7)
    #expect(p.expire(now:0.21) == nil)
    #expect(p.expire(now:0.221) == MobileAirOutput())
    #expect(p.frame(hand:hand(0.1),at:0.23,now:0.36).keys == 0)
}

@Test func mobileStringsPartialExpiryKeepsOnlyUnexpiredKeys() throws {
    var p = try #require(MobileAirInstrument(mode:.strings,keys:7))
    _ = p.frame(hand:hand(0.1),at:0,now:0)
    _ = p.frame(hand:hand(0.1),at:0.05,now:0.05)
    #expect(p.frame(hand:hand(0.4),at:0.1,now:0.1).keys == 1)
    #expect(p.frame(hand:hand(0.65),at:0.16,now:0.16).keys == 3)
    #expect(p.expire(now:0.23)?.keys == 2)
    #expect(p.expire(now:0.29)?.keys == 0)
}
