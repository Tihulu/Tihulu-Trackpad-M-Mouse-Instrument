#if os(macOS)
import Testing
import NoSpeakerCore
@testable import NoSpeakerMac

@Test func customTouchScaleFrettedVersusFretlessAndDrums() throws {
    var custom = CustomScale()
    custom.intervals = [0,2,4,7,9]
    custom.centOffsets = [4:-25]
    var config = TouchInstrumentConfiguration(baseMIDINote: 60, scale: .chromatic,
                                                customScale: custom)
    #expect(config.mappedMIDINotes == [60,62,64,67,69,72,74,76,79,81,84])
    #expect(config.permitsMelodicMIDI)
    config.trackpadOutput = .midiInstrument
    #expect(!config.permitsMelodicMIDI)
    config.trackpadInstrument = .drums
    #expect(config.permitsMelodicMIDI)
    config.trackpadInstrument = .melodic
    config.fretless = true
    #expect(config.permitsMelodicMIDI)
    #expect(config.mappedMIDINotes == Array(60...84))
    config.fretless = false
    custom.allowEqualTemperedMIDI = true
    config.customScale = custom
    #expect(config.permitsMelodicMIDI)
    let actual = try #require(config.frettedFrequency(midi: 64))
    let expected = try #require(custom.tunedFrequency(midi: 64, root: 60))
    #expect(actual == expected)
}

@Test func touchConfigurationRejectsInvalidScaleInputsBeforeIntConversion() {
    #expect(TouchScale.chromatic.mappedMIDINotes(root:Int.max,zoneWidth:1).isEmpty)
    #expect(TouchScale.chromatic.mappedMIDINotes(root:60,zoneWidth:.nan).isEmpty)
    var config = TouchInstrumentConfiguration()
    config.pitchSpanSemitones = .infinity
    #expect(config.mappedMIDINotes.isEmpty)
    config.pitchSpanSemitones = 24
    config.zoneWidth = 1
    #expect(!config.mappedMIDINotes.isEmpty)
}

@Test func touchHapticResetDistinguishesVolumeFromMappingChanges() {
    let previous = TouchInstrumentConfiguration()
    var next = previous
    next.masterLevel = 0.3
    #expect(!next.requiresHapticReset(comparedTo:previous))
    next.baseMIDINote = 60
    #expect(next.requiresHapticReset(comparedTo:previous))
    next = previous
    next.fretless.toggle()
    #expect(next.requiresHapticReset(comparedTo:previous))
    next = previous
    next.trackpadOutput = .midiInstrument
    #expect(next.requiresHapticReset(comparedTo:previous))
}
#endif
