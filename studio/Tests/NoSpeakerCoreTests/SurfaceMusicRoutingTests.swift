import Foundation
import Testing
@testable import NoSpeakerCore

@Test func gmDrumPadsUseChannelTenAndRealPercussionNotes() {
    #expect(GMDrumPads.midiChannel == 9)
    #expect(GMDrumPads.standard[0].midiNote == 36)
    #expect(GMDrumPads.standard[1].midiNote == 38)
    #expect(GMDrumPads.standard[2].midiNote == 42)
    #expect(GMDrumPads.standard[3].midiNote == 46)
    #expect(GMDrumPads.name(for: 39) == "Clap")
}

@Test func gmDrumPadLayoutsHaveExpectedLengths() {
    #expect(DrumPadLayout.compact8.pads.count == 8)
    #expect(DrumPadLayout.standard12.pads.count == 12)
    #expect(DrumPadLayout.extended16.pads.count == 16)
}

@Test func drumPadCoordinatesClampToValidZones() {
    #expect(GMDrumPads.pad(forNormalizedX: -2, layout: .compact8).midiNote == 36)
    #expect(GMDrumPads.pad(forNormalizedX: 0.2499, layout: .compact8).midiNote == 38)
    #expect(GMDrumPads.pad(forNormalizedX: 0.25, layout: .compact8).midiNote == 42)
    #expect(GMDrumPads.pad(forNormalizedX: 1, layout: .compact8).midiNote == 47)
    #expect(GMDrumPads.pad(forNormalizedX: 10, layout: .standard12).midiNote == 56)
    #expect(GMDrumPads.pad(forNormalizedX: .nan, layout: .standard12).midiNote == 36)
}

@Test func independentSurfaceOutputDestinations() {
    #expect(SurfaceOutputRoute.trackpadHaptic.sendsHaptics)
    #expect(!SurfaceOutputRoute.trackpadHaptic.sendsMIDI)
    #expect(SurfaceOutputRoute.midiInstrument.sendsMIDI)
    #expect(!SurfaceOutputRoute.midiInstrument.sendsHaptics)
    #expect(SurfaceOutputRoute.both.sendsMIDI)
    #expect(SurfaceOutputRoute.both.sendsHaptics)
}

@Test func touchDrumsReuseSequencerAndHaveDistinctSafeProfiles() throws {
    let pairs: [(Int, DrumVoice)] = [(36, .kick), (38, .snare), (42, .closedHat), (46, .openHat), (39, .clap), (47, .tom)]
    for (note, voice) in pairs {
        #expect(HapticPatternRenderer.drumFrame(midiNote: note, velocity: 0.8) == HapticPatternRenderer.drumFrame(voice, velocity: 0.8))
    }
    let frames = try GMDrumPads.standard.map { pad in
        try #require(HapticPatternRenderer.drumFrame(midiNote: pad.midiNote, velocity: 0.8))
    }
    for (index, frame) in frames.enumerated() {
        #expect(HapticSafetyPolicy().clamp(frame) == frame)
        for other in frames.dropFirst(index + 1) {
            #expect(frame != other)
        }
    }
    #expect(HapticPatternRenderer.drumFrame(midiNote: 0, velocity: 0.8) == nil)
}

@Test func standardTouchControlTargetMatchesNoteChannel() {
    for base in -1...16 {
        for drums in [false,true] {
            let expected = drums && base == 9 ? 0 : min(15,max(0,base))
            #expect(SurfaceMIDIChannel.melodic(base:base,hasMIDIDrums:drums) == expected)
            #expect(SurfaceMIDIChannel.controlTarget(base:base,hasMIDIDrums:drums,hasMIDIMelody:true,isMPE:false) == expected)
            #expect(SurfaceMIDIChannel.controlTarget(base:base,hasMIDIDrums:drums,hasMIDIMelody:false,isMPE:false) == nil)
            #expect(SurfaceMIDIChannel.controlTarget(base:base,hasMIDIDrums:drums,hasMIDIMelody:true,isMPE:true) == nil)
        }
    }
}

@Test func physicalDrumGridCentersAndEdgesMatchPreviewRows() {
    for layout in [DrumPadLayout.grid8,.grid12,.grid16] {
        #expect(layout.columns == 4)
        #expect(layout.rows * layout.columns == layout.pads.count)
        for index in layout.pads.indices {
            let x = (Double(index % layout.columns) + 0.5) / Double(layout.columns)
            let y = 1 - (Double(index / layout.columns) + 0.5) / Double(layout.rows)
            #expect(layout.padIndex(x:x,y:y) == index)
            #expect(layout.pad(x:x,y:y) == layout.pads[index])
        }
        #expect(layout.padIndex(x:0,y:1) == 0)
        #expect(layout.padIndex(x:1,y:0) == layout.pads.count - 1)
        #expect(layout.padIndex(x:0.25,y:1) == 1)
        #expect(layout.padIndex(x:.nan,y:1) == nil)
        #expect(layout.padIndex(x:0,y:.infinity) == nil)
        #expect(layout.padIndex(x:-0.01,y:1) == nil)
        #expect(layout.padIndex(x:1,y:1.01) == nil)
    }
}

@Test func legacyDrumLayoutsPreserveArchiveAndStripMapping() throws {
    for layout in [DrumPadLayout.compact8,.standard12,.extended16] {
        #expect(layout.rows == 1)
        for index in layout.pads.indices {
            let x = (Double(index)+0.5)/Double(layout.pads.count)
            for y in [0.0,0.5,1.0] {
                #expect(layout.pad(x:x,y:y) == GMDrumPads.pad(forNormalizedX:x,layout:layout))
            }
        }
        #expect(try JSONDecoder().decode(DrumPadLayout.self,from:JSONEncoder().encode(layout)) == layout)
    }
    #expect(try JSONDecoder().decode(DrumPadLayout.self,from:Data("\"12 Pads\"".utf8)) == .standard12)
}

@Test func gridDrumStrikesStayOnInitialPadUntilRelease() {
    for layout in [DrumPadLayout.grid8,.grid12,.grid16] {
        for initial in layout.pads {
            for dragged in layout.pads {
                #expect(layout.strikeNote(at:dragged.midiNote,previousDownNote:initial.midiNote) == initial.midiNote)
                #expect(layout.strikeNote(at:dragged.midiNote,previousDownNote:nil) == dragged.midiNote)
            }
        }
    }
    #expect(DrumPadLayout.grid8.strikeNote(at:36,previousDownNote:127) == 36)
    #expect(DrumPadLayout.compact8.strikeNote(at:38,previousDownNote:36) == 38)
}

@Test func physicalChordGridAndSharedGateOwnership() throws {
    for slot in 0..<8 {
        #expect(PhysicalChordGrid.slot(x:(Double(slot%4)+0.5)/4,y:1-(Double(slot/4)+0.5)/2) == slot)
    }
    #expect(PhysicalChordGrid.slot(x:.nan,y:0) == nil)
    var ledger = LegacyNoteOwners<String>()
    var gates = PhysicalChordGates<Int>()
    func target(_ n:Int) -> SensorDestination { .init(.note,channel:0,number:n) }
    func owner(_ c:Int,_ t:SensorDestination) -> String { "\(c)-\(t.channel)-\(t.number)" }
    let a = Set([target(60),target(64),target(67)])
    let b = Set([target(64),target(67),target(71)])
    #expect(gates.reconcile([1:a,2:b],velocity:[1:90,2:90],ledger:&ledger,owner:owner).count == 4)
    #expect(gates.reconcile([2:b],velocity:[2:90],ledger:&ledger,owner:owner) == [.init(target(60),value:0)])
    #expect(gates.reconcile([3:b],velocity:[3:90],ledger:&ledger,owner:owner).isEmpty)
    _ = ledger.press("external",channel:0,note:64,velocity:100)
    #expect(gates.reconcile([:],velocity:[:],ledger:&ledger,owner:owner).count == 2)
    #expect(ledger.active == [target(64)])
    #expect(ledger.release("external") == [.init(target(64),value:0)])
}

@Test func physicalChordMIDIRouteRejectsUnsupportedCombinations() {
    let bank = ChordBank()
    #expect(PhysicalChordGrid.permitsMIDI(bank:bank,isMPE:false,mixedFretless:false))
    #expect(!PhysicalChordGrid.permitsMIDI(bank:bank,isMPE:true,mixedFretless:false))
    #expect(!PhysicalChordGrid.permitsMIDI(bank:bank,isMPE:false,mixedFretless:true))
}

@Test func physicalChordInvalidSnapshotReleasesOnlyChordOwners() {
    var ledger = LegacyNoteOwners<String>()
    var gates = PhysicalChordGates<Int>()
    let shared = SensorDestination(.note,channel:0,number:60)
    let chordOnly = SensorDestination(.note,channel:0,number:64)
    func owner(_ c:Int,_ t:SensorDestination) -> String { "\(c)-\(t.channel)-\(t.number)" }
    _ = ledger.press("melody",channel:0,note:60,velocity:100)
    let valid = gates.reconcile([1:[shared,chordOnly]],velocity:[1:90],ledger:&ledger,owner:owner)
    #expect(valid == [.init(chordOnly,value:90)])
    let invalid = gates.reconcile([1:[shared,chordOnly]],velocity:[1:0],ledger:&ledger,owner:owner)
    #expect(invalid == [.init(chordOnly,value:0)])
    #expect(ledger.active == [shared])
    #expect(gates.channels.isEmpty)
}

@Test func physicalChordSharedNoteVelocityIsDeterministic() {
    var ledger = LegacyNoteOwners<String>()
    var gates = PhysicalChordGates<Int>()
    let note = SensorDestination(.note,channel:0,number:60)
    let commands = gates.reconcile([2:[note],1:[note]],velocity:[2:40,1:100],
        ledger:&ledger,owner:{ c,t in "\(c)-\(t.number)" })
    #expect(commands == [.init(note,value:100)])
}
