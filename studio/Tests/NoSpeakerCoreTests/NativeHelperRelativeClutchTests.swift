import Testing
@testable import NoSpeakerCore

private typealias Clutch = NativeHelperRelativeClutch
private func clutch() throws -> Clutch {
    try #require(Clutch(surface: .magicMouse, lanes: [
        .x: .init(reference: 8192, upper: 16383),
        .y: .init(reference: 90, upper: 127),
        .contactSize: .init(reference: 64, upper: 127)
    ]))
}
private func contact(_ id: Int = 1, x: Double = 0.5, y: Double = 0.5, size: Double = 0.5,
                     surface: Clutch.Surface = .magicMouse) -> Clutch.Contact {
    .init(surface: surface, id: id, x: x, y: y, contactSize: size)
}
@Test func nativeRelativeClutchIndependentLanesAndNeutralStart() throws {
    var state = try clutch()
    #expect(state.frame([contact()], receipt: 0) == .blocked)
    #expect(state.frame([], receipt: 1) == .idle)
    #expect(state.frame([contact(x: 0.75)], receipt: 2) == .anchored)
    #expect(state.frame([contact(x: 0.75)], receipt: 3) == .idle)
    #expect(state.frame([contact(x: 0.875, y: 0.6)], receipt: 4) == .movement([.x: 10240, .y: 103]))
    #expect(state.frame([contact(x: 0.75, size: 0.75)], receipt: 5) == .movement([.x: 8192, .y: 90, .contactSize: 96]))
    #expect(state.frame([], receipt: 6) == .releaseRequired)
    #expect(state.frame([contact(x: 0.1)], receipt: 7) == .anchored)
}
@Test func nativeRelativeClutchRejectsMembershipChangeUntilNeutral() throws {
    var state = try clutch()
    _ = state.frame([], receipt: 0)
    _ = state.frame([contact()], receipt: 1)
    #expect(state.frame([contact(),contact(2)], receipt: 2) == .releaseRequired)
    #expect(state.frame([contact(2)], receipt: 3) == .blocked)
    #expect(state.frame([], receipt: 4) == .idle)
    #expect(state.frame([contact(2)], receipt: 5) == .anchored)
    #expect(state.frame([contact(3)], receipt: 6) == .releaseRequired)
    #expect(state.frame([contact(3)], receipt: 7) == .blocked)
}
@Test func nativeRelativeClutchRejectsForeignInvalidAndRegressedFrames() throws {
    var state = try clutch()
    _ = state.frame([], receipt: 1)
    _ = state.frame([contact()], receipt: 2)
    #expect(state.frame([contact(surface: .trackpad)], receipt: 3) == .releaseRequired)
    #expect(state.frame([], receipt: 2) == .blocked)
    #expect(state.frame([], receipt: 4) == .idle)
    _ = state.frame([contact()], receipt: 5)
    #expect(state.frame([contact(x: .nan)], receipt: 6) == .releaseRequired)
    #expect(state.frame([contact()], receipt: 7) == .blocked)
    _ = state.frame([], receipt: 8)
    _ = state.frame([contact()], receipt: 9)
    #expect(state.invalidate() == .releaseRequired)
    #expect(state.invalidate() == .blocked)
    #expect(state.frame([contact()], receipt: 10) == .blocked)
}
@Test func nativeRelativeClutchRejectsInvalidLaneConfiguration() {
    #expect(Clutch(surface: .trackpad, lanes: [:]) == nil)
    #expect(Clutch(surface: .trackpad, lanes: [.x: .init(reference: 128, upper: 127)]) == nil)
    #expect(Clutch(surface: .trackpad, lanes: [.y: .init(reference: 50, upper: 127, gain: .nan)]) == nil)
}
