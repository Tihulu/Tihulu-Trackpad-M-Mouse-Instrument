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
    #expect(config.permitsMelodicMIDI(isMPE:true))
    #expect(config.melodicMPEPitch(midi:64,isMPE:true)?.bend == 7168)
    #expect(config.melodicMPEPitch(midi:64,isMPE:false) == nil)
    config.trackpadInstrument = .drums
    #expect(config.permitsMelodicMIDI)
    config.trackpadInstrument = .melodic
    config.fretless = true
    #expect(config.permitsMelodicMIDI)
    #expect(config.mappedMIDINotes == Array(60...84))
    #expect(config.melodicMPEPitch(midi:64,isMPE:true) == nil)
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

@Test func independentStringLayoutsPreserveLegacyFallbackAndResetMapping() throws {
    let guitar = StringSurfaceLayout(tuning:.standard,frets:12)
    let bass = StringSurfaceLayout(tuning:.bass,frets:24)
    var config = TouchInstrumentConfiguration(surfaceSelection:.both,
        trackpadInstrument:.guitar,magicMouseInstrument:.fretlessStrings,
        stringLayout:guitar)
    #expect(config.strings(for:.trackpad) == guitar)
    #expect(config.strings(for:.magicMouse) == guitar)
    let shared = config
    config.mouseStringLayout = bass
    #expect(config.strings(for:.trackpad) == guitar)
    #expect(config.strings(for:.magicMouse) == bass)
    #expect(config.requiresHapticReset(comparedTo:shared))
    #expect(config.strings(for:.trackpad).cell(x:1,y:0)?.note == 52)
    #expect(config.strings(for:.magicMouse).continuousCell(x:1,y:0)?.pitch == 52)
    #expect(config.strings(for:.magicMouse).continuousCell(x:0,y:1)?.pitch == 43)
    config.mouseStringLayout = nil
    #expect(config == shared)
}

@Test func fretlessStringMIDIRequiresMPEOnlyForMIDIRoutedSurfaces() {
    var config = TouchInstrumentConfiguration(surfaceSelection:.both,
        trackpadInstrument:.guitar,magicMouseInstrument:.fretlessStrings,
        trackpadOutput:.midiInstrument,magicMouseOutput:.trackpadHaptic)
    #expect(config.permitsStringMIDI(isMPE:false))
    config.magicMouseOutput = .both
    #expect(!config.permitsStringMIDI(isMPE:false))
    #expect(config.permitsStringMIDI(isMPE:true))
    config.mouseStringLayout = StringSurfaceLayout(frets:Int.max)
    #expect(!config.permitsStringMIDI(isMPE:true))
    config.surfaceSelection = .trackpad
    #expect(config.permitsStringMIDI(isMPE:false))
    config.surfaceSelection = .both
    config.mouseStringLayout = .init(tuning:.bass)
    config.magicMouseInstrument = .melodic
    config.fretless = true
    #expect(!config.permitsStringMIDI(isMPE:false))
    #expect(config.permitsStringMIDI(isMPE:true))
}
@Test func microtonalFrettedMIDIRequiresMPEButHapticDoesNot() {
    var config = TouchInstrumentConfiguration(surfaceSelection:.both,
        trackpadInstrument:.guitar,magicMouseInstrument:.guitar,
        trackpadOutput:.midiInstrument,magicMouseOutput:.trackpadHaptic,
        stringLayout:.init(),mouseStringLayout:.init(fretDivision:.edo53))
    #expect(config.permitsStringMIDI(isMPE:false))
    config.magicMouseOutput = .both
    #expect(!config.permitsStringMIDI(isMPE:false))
    #expect(config.permitsStringMIDI(isMPE:true))
    config.mouseStringLayout = .init(customFretCents:[0,181,355,1200])
    #expect(!config.permitsStringMIDI(isMPE:false))
    #expect(config.permitsStringMIDI(isMPE:true))
    config.mouseStringLayout = .init(customFretCents:[0,1201])
    #expect(!config.permitsStringMIDI(isMPE:true))
}
@Test func polyphonicFretlessMPERequirementFollowsSelectedMIDISurfaces() {
    var config = TouchInstrumentConfiguration(fretless:true)
    #expect(!config.requiresPolyphonicFretlessMPE(multiTouch:true))
    config.trackpadOutput = .both
    #expect(config.requiresPolyphonicFretlessMPE(multiTouch:true))
    #expect(!config.requiresPolyphonicFretlessMPE(multiTouch:false))
    config.fretless = false
    #expect(!config.requiresPolyphonicFretlessMPE(multiTouch:true))
    config.fretless = true
    config.trackpadInstrument = .drums
    #expect(!config.requiresPolyphonicFretlessMPE(multiTouch:true))
    config.surfaceSelection = .both
    #expect(config.requiresPolyphonicFretlessMPE(multiTouch:true))
    config.magicMouseOutput = .trackpadHaptic
    #expect(!config.requiresPolyphonicFretlessMPE(multiTouch:true))
    config.magicMouseOutput = .midiInstrument
    config.magicMouseInstrument = .guitar
    #expect(!config.requiresPolyphonicFretlessMPE(multiTouch:true))
}
@Test func separateDAWSurfaceChannelsRequireTwoPitchedStandardOutputs() {
    var config = TouchInstrumentConfiguration(surfaceSelection:.both,
        trackpadOutput:.midiInstrument,magicMouseOutput:.midiInstrument)
    #expect(config.permitsSeparateDAWSurfaceChannels)
    config.surfaceSelection = .trackpad
    #expect(!config.permitsSeparateDAWSurfaceChannels)
    config.surfaceSelection = .both
    config.magicMouseOutput = .trackpadHaptic
    #expect(!config.permitsSeparateDAWSurfaceChannels)
    config.magicMouseOutput = .midiInstrument
    config.magicMouseInstrument = .drums
    #expect(!config.permitsSeparateDAWSurfaceChannels)
    config.magicMouseInstrument = .melodic
    config.fretless = true
    #expect(!config.permitsSeparateDAWSurfaceChannels)
    config.fretless = false
    config.magicMouseInstrument = .fretlessStrings
    #expect(!config.permitsSeparateDAWSurfaceChannels)
}
@Test func validMasterGainDoesNotInvalidateMusicalSnapshots() {
    let initial = TouchInstrumentConfiguration()
    var next = initial
    next.masterLevel = 0.3
    #expect(!next.requiresSampleInvalidation(comparedTo:initial))
    next.masterLevel = 0
    #expect(!next.requiresSampleInvalidation(comparedTo:initial))
    next.masterLevel = .nan
    #expect(next.requiresSampleInvalidation(comparedTo:initial))
    #expect(initial.requiresSampleInvalidation(comparedTo:next))
    next = initial
    next.fretless.toggle()
    #expect(next.requiresSampleInvalidation(comparedTo:initial))
    next = initial
    next.zoneWidth = 1.5
    #expect(next.requiresSampleInvalidation(comparedTo:initial))
}
#endif
