import Testing
@testable import NoSpeakerCore

struct RelativeAngularTraceTests {
    private func wrapped(_ angle: Int) -> Double {
        Double((angle % 360 + 360) % 360)
    }

    @Test(arguments: [5, 45, 180], [-1, 1])
    func reversibleWrappedTravel(sweep: Int, direction: Int) throws {
        for origin in 0..<360 {
            var clutch = try #require(RelativeAngularClutch(sweepDegrees: Double(sweep), maximumStepDegrees: 90))
            #expect(clutch.begin(angle: Double(origin), receipt: 0) == .anchored(0.5))
            // Traverse ten full turns, then reverse to the original anchor.
            for index in 1...80 {
                let distance = direction * 90 * min(index, 80 - index)
                let expected = min(1.0, max(0.0, 0.5 + Double(distance) / Double(2 * sweep)))
                #expect(clutch.update(angle: wrapped(origin + distance), receipt: Double(index)) == .position(expected))
            }
            #expect(clutch.end() == .releaseRequired)
        }
    }

    @Test(arguments: [1, 20, 90, 179], [-1, 1])
    func exactStepLimitAndRejectedReceipt(maximum: Int, direction: Int) throws {
        for origin in 0..<360 {
            var clutch = try #require(RelativeAngularClutch(sweepDegrees: 180, maximumStepDegrees: Double(maximum)))
            #expect(clutch.begin(angle: Double(origin), receipt: 1) == .anchored(0.5))
            let distance = direction * maximum
            #expect(clutch.update(angle: wrapped(origin + distance), receipt: 2) == .position(0.5 + Double(distance) / 360))
            let rejectedAngle = wrapped(origin + distance + direction * (maximum + 1))
            #expect(clutch.update(angle: rejectedAngle, receipt: 3) == .releaseRequired)
            #expect(clutch.update(angle: Double(origin), receipt: 4) == .blocked)
            _ = clutch.end()
            #expect(clutch.begin(angle: Double(origin), receipt: 4) == .blocked)
            _ = clutch.end()
            #expect(clutch.begin(angle: Double(origin), receipt: 5) == .anchored(0.5))
        }
    }

    @Test(arguments: [-1, 1])
    func exactTravelLimitAndRecovery(direction: Int) throws {
        for origin in 0..<360 {
            var clutch = try #require(RelativeAngularClutch(sweepDegrees: 45, maximumStepDegrees: 90))
            #expect(clutch.begin(angle: Double(origin), receipt: 0) == .anchored(0.5))
            for index in 1...40 {
                #expect(clutch.update(angle: wrapped(origin + direction * 90 * index), receipt: Double(index)) == .position(direction > 0 ? 1 : 0))
            }
            #expect(clutch.update(angle: wrapped(origin + direction * 3601), receipt: 41) == .releaseRequired)
            #expect(clutch.update(angle: Double(origin), receipt: 42) == .blocked)
            _ = clutch.end()
            #expect(clutch.begin(angle: Double(origin), receipt: 42) == .blocked)
            _ = clutch.end()
            #expect(clutch.begin(angle: Double(origin), receipt: 43) == .anchored(0.5))
        }
    }
}
