import Foundation
import Testing
@testable import NoSpeakerCore

@Test func touchBarLocalSharedNoteAndSustain() {
    var state = TouchBarNoteState()
    #expect(state.key(60, owner: .screenPiano, pressed: true, channel: 0, velocity: 100).count == 1)
    #expect(state.key(60, owner: .nativeRibbon, pressed: true, channel: 0, velocity: 100).isEmpty)
    #expect(state.key(60, owner: .screenPiano, pressed: false, channel: 0, velocity: 100).isEmpty)
    _ = state.setSustain(true, channel: 0, velocity: 100)
    #expect(state.key(60, owner: .nativeRibbon, pressed: false, channel: 0, velocity: 100).isEmpty)
    #expect(state.notes == [60])
    #expect(state.setSustain(false, channel: 0, velocity: 100) == [.init(.init(.note, number: 60), value: 0)])
    #expect(state.notes.isEmpty)
}

@Test func touchBarLocalBendExpressionAndReset() throws {
    var state = TouchBarNoteState()
    _ = state.key(60, owner: .screenRibbon, pressed: true, channel: 2, velocity: 100)
    state.setBend(0.75)
    state.setExpression(0.5)
    let frame = try #require(state.frame(velocity: 100))
    let hz = try MusicTheory.frequency(midi: 66)
    #expect(abs(frame.tones[0].frequencyHz - hz) < 0.001)
    #expect(abs(frame.level - 50.0 / 127) < 0.001)
    state.setBend(.nan)
    #expect(state.bend == 6)
    #expect(state.reset(channel: 2) == [.init(.init(.note, channel: 2, number: 60), value: 0)])
    #expect(state.frame(velocity: 100) == nil)
    #expect(state.expression == 1)
    #expect(state.bend == 0)
}

@Test func touchBarOutputProfileBackwardCompatibility() throws {
    var profile = TouchBarProfile()
    let data = try JSONEncoder().encode(profile)
    #expect(try JSONDecoder().decode(TouchBarProfile.self, from: data).effectiveOutput == .midi)
    profile.musicalOutput = .both
    #expect(try JSONDecoder().decode(TouchBarProfile.self, from: JSONEncoder().encode(profile)).effectiveOutput == .both)
}
