import Foundation
import Testing
@testable import NoSpeakerCore

@Test func customFretsMatchTwoOctaveWidthAndRoot() {
    var scale = CustomScale()
    scale.intervals = [0,2,5,7,10]
    #expect(scale.mappedMIDINotes(root: 60, zoneWidth: 1) == [60,62,65,67,70,72,74,77,79,82,84])
    #expect(scale.mappedMIDINotes(root: 60, zoneWidth: 2).count == 6)
    #expect(scale.mappedMIDINotes(root: 60, zoneWidth: 0.5).count == 22)
    #expect(scale.mappedMIDINotes(root: 126, zoneWidth: 1) == [126])
    #expect(scale.mappedMIDINotes(root: 60, zoneWidth: .nan).isEmpty)
}

@Test func customFretsUseRootRelativeCentsAtEveryOctave() throws {
    var scale = CustomScale()
    scale.centOffsets = [4:-30,7:15]
    let f = try #require(scale.tunedFrequency(midi: 66, root: 62))
    let nominal = try MusicTheory.frequency(midi: 66)
    #expect(abs(f - nominal * pow(2, -30.0/1200)) < 0.000001)
    let octave = try #require(scale.tunedFrequency(midi: 78, root: 62))
    #expect(abs(octave - f * 2) < 0.000001)
    let offScale = try #require(scale.tunedFrequency(midi: 63, root: 62))
    #expect(offScale == (try MusicTheory.frequency(midi: 63)))
    #expect(scale.tunedFrequency(midi: -1, root: 62) == nil)
}
