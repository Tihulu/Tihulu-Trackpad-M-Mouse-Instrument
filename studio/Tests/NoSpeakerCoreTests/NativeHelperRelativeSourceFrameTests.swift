import Testing
@testable import NoSpeakerCore

private typealias Clutch = NativeHelperRelativeClutch
private func observation(_ time: Double, count: Int, contacts: [Clutch.Contact] = [],
                         surface: Clutch.Surface = .magicMouse, consistent: Bool = true) -> Clutch.SourceFrame {
    .init(surface: surface, rawDownCount: count, sourceConsistent: consistent, contacts: contacts, receipt: time)
}
private func finger(_ x: Double = 0.5) -> Clutch.Contact {
    .init(surface: .magicMouse, id: 1, x: x, y: 0.5, contactSize: 0.5)
}
private func makeClutch() throws -> Clutch {
    try #require(Clutch(surface: .magicMouse, lanes: [.x: .init(reference: 8192, upper: 16383)]))
}

@Test func relativeSourceFrameCannotMistakeDroppedContactForNeutral() throws {
    var clutch = try makeClutch()
    let incomplete = observation(1, count: 1)
    #expect(!incomplete.isGenuineNeutral && !incomplete.isComplete)
    #expect(clutch.frame(incomplete) == .blocked)
    #expect(clutch.frame(observation(2, count: 1, contacts: [finger()])) == .blocked)
    #expect(clutch.frame(observation(3, count: 0)) == .idle)
    #expect(clutch.frame(observation(4, count: 1, contacts: [finger()])) == .anchored)
    #expect(clutch.frame(observation(5, count: 1, contacts: [finger(0.75)])) == .movement([.x: 12288]))
    #expect(clutch.frame(observation(6, count: 1)) == .releaseRequired)
    #expect(clutch.frame(observation(7, count: 1, contacts: [finger()])) == .blocked)
    #expect(clutch.frame(observation(8, count: 0)) == .idle)
    #expect(clutch.frame(observation(9, count: 1, contacts: [finger()])) == .anchored)
}

@Test func relativeSourceFrameRejectsForeignNeutralAndStaleReceipt() throws {
    var clutch = try makeClutch()
    #expect(clutch.frame(observation(1, count: 0, surface: .trackpad)) == .blocked)
    #expect(clutch.frame(observation(2, count: 1, contacts: [finger()])) == .blocked)
    #expect(clutch.frame(observation(3, count: 0)) == .idle)
    #expect(clutch.frame(observation(4, count: 1, contacts: [finger()])) == .anchored)
    #expect(clutch.frame(observation(6, count: 0, consistent: false)) == .releaseRequired)
    #expect(clutch.frame(observation(5, count: 0)) == .blocked)
    #expect(clutch.frame(observation(7, count: 1, contacts: [finger()])) == .blocked)
    #expect(clutch.frame(observation(8, count: 0)) == .idle)
}

@Test func relativeSourceFrameRejectsPartialMultiContactAndMalformedDomains() throws {
    var clutch = try makeClutch()
    _ = clutch.frame(observation(1, count: 0))
    _ = clutch.frame(observation(2, count: 1, contacts: [finger()]))
    #expect(clutch.frame(observation(3, count: 2, contacts: [finger()])) == .releaseRequired)
    #expect(!observation(4, count: -1).isComplete)
    #expect(!observation(4, count: 1, contacts: [finger(.nan)]).isComplete)
    #expect(!observation(4, count: 1, contacts: [finger(1.01)]).isComplete)
    #expect(!observation(4, count: 0, consistent: false).isGenuineNeutral)
    #expect(clutch.frame(observation(4, count: 0)) == .idle)
    #expect(clutch.frame(observation(5, count: 1, contacts: [finger()])) == .anchored)
}
