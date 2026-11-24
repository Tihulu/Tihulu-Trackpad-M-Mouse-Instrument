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

@Test func frettedStringGridMapsAllCentersAndBoundaries() throws {
    for tuning in StringTuning.allCases {
        for frets in 4...24 {
            let layout = StringSurfaceLayout(tuning:tuning,frets:frets)
            for row in 0..<layout.rows {
                for fret in 0..<layout.columns {
                    let cell = try #require(layout.cell(x:(Double(fret)+0.5)/Double(layout.columns),
                        y:1-(Double(row)+0.5)/Double(layout.rows)))
                    #expect(cell.string == row && cell.fret == fret)
                    #expect(cell.note == tuning.openNotes[row]+fret)
                }
            }
            #expect(layout.cell(x:0,y:1)?.note == tuning.openNotes.first)
            #expect(layout.cell(x:1,y:0)?.note == tuning.openNotes.last.map { $0+frets })
            #expect(layout.cell(x:.nan,y:1) == nil)
            #expect(layout.cell(x:0,y:-0.1) == nil)
            #expect(try JSONDecoder().decode(StringSurfaceLayout.self,from:JSONEncoder().encode(layout)) == layout)
        }
    }
}
@Test func frettedStringTuningsAndRouteSafety() {
    #expect(StringTuning.standard.openNotes == [64,59,55,50,45,40])
    #expect(StringTuning.dropD.openNotes.last == 38)
    #expect(StringTuning.openG.openNotes == [62,59,55,50,43,38])
    #expect(StringTuning.bass.openNotes == [43,38,33,28])
    let valid = StringSurfaceLayout()
    #expect(valid.permitsMIDI(mixedFretless:false,isMPE:false))
    #expect(!valid.permitsMIDI(mixedFretless:true,isMPE:false))
    #expect(valid.permitsMIDI(mixedFretless:true,isMPE:true))
    for frets in [Int.min,0,25,Int.max] {
        let bad = StringSurfaceLayout(frets:frets)
        #expect(!bad.isValid)
        #expect(bad.cell(x:0,y:0) == nil)
        #expect(!bad.permitsMIDI(mixedFretless:false,isMPE:true))
    }
}

@Test func customStringTuningValidatesRangeAndBackwardCompatibility() throws {
    let old = Data("{\"tuning\":\"Guitar · Standard\",\"frets\":12}".utf8)
    let decoded = try JSONDecoder().decode(StringSurfaceLayout.self,from:old)
    #expect(decoded.customOpenNotes == nil)
    #expect(decoded.openNotes == StringTuning.standard.openNotes)
    let custom = StringSurfaceLayout(frets:24,customOpenNotes:[55,55,50,48,43,38,33,28])
    #expect(custom.isValid)
    #expect(custom.rows == 8)
    #expect(custom.cell(x:1,y:0)?.note == 52)
    #expect(try JSONDecoder().decode(StringSurfaceLayout.self,from:JSONEncoder().encode(custom)) == custom)
    for notes in [[],[0,1,2],[1,2,3,104],[1,2,3,-1],[1,2,3,Int.max],Array(repeating:40,count:9)] {
        let invalid = StringSurfaceLayout(frets:24,customOpenNotes:notes)
        #expect(!invalid.isValid)
        #expect(invalid.cell(x:1,y:1) == nil)
    }
}

@Test func fretlessStringPitchIsContinuousAndBendReconstructsPitch() throws {
    for tuning in StringTuning.allCases {
        for span in 4...24 {
            let layout = StringSurfaceLayout(tuning:tuning,frets:span)
            for row in 0..<layout.rows {
                let y = 1-(Double(row)+0.5)/Double(layout.rows)
                var prior = -1.0
                for step in 0...100 {
                    let x = Double(step)/100
                    let cell = try #require(layout.continuousCell(x:x,y:y))
                    #expect(cell.string == row)
                    #expect(cell.pitch > prior)
                    prior = cell.pitch
                    #expect((1...12).contains(cell.bendRange))
                    #expect((0...16383).contains(cell.bend))
                    let delta = Double(cell.bend-8192)
                    let reconstructed = Double(cell.anchor) + delta/Double(delta < 0 ? 8192 : 8191)*Double(cell.bendRange)
                    #expect(abs(reconstructed-cell.pitch) <= 0.001)
                    #expect(abs(cell.pitch-(Double(layout.openNotes[row])+x*Double(span))) < 0.000001)
                }
            }
        }
    }
}
@Test func fretlessStringInvalidCoordinatesAndRangeAreRejected() {
    let layout = StringSurfaceLayout()
    #expect(layout.continuousCell(x:.nan,y:0) == nil)
    #expect(layout.continuousCell(x:0,y:.infinity) == nil)
    #expect(layout.continuousCell(x:-0.001,y:0) == nil)
    #expect(layout.continuousCell(x:1.001,y:0) == nil)
    #expect(StringSurfaceLayout(frets:Int.max).continuousCell(x:0,y:0) == nil)
    #expect(StringSurfaceLayout(frets:24,customOpenNotes:[104,1,2,3]).continuousCell(x:0,y:0) == nil)
}

@Test func microtonalStringDivisionsReconstructExactPitchAndBoundSpan() throws {
    for division in [StringFretDivision.edo24,.edo53] {
        for span in 4...24 {
            let layout = StringSurfaceLayout(frets:span,fretDivision:division)
            #expect(layout.columns == span*division.rawValue/12+1)
            for row in 0..<layout.rows {
                let y = 1-(Double(row)+0.5)/Double(layout.rows)
                for step in 0..<layout.columns {
                    let x = (Double(step)+0.5)/Double(layout.columns)
                    let cell = try #require(layout.microtonalCell(x:x,y:y))
                    let expected = Double(layout.openNotes[row])+Double(step)*12/Double(division.rawValue)
                    #expect(abs(cell.pitch-expected) < 0.000001)
                    #expect(cell.pitch <= Double(layout.openNotes[row]+span))
                    let delta = Double(cell.bend-8192)
                    let reconstructed = Double(cell.anchor)+2*delta/Double(delta < 0 ? 8192 : 8191)
                    #expect(abs(reconstructed-expected) < 0.00013)
                }
            }
            #expect(layout.microtonalCell(x:.nan,y:1) == nil)
        }
    }
}
@Test func microtonalDivisionArchiveAndFretlessIndependence() throws {
    let normal = StringSurfaceLayout()
    #expect(normal.effectiveDivision == .edo12)
    #expect(normal.microtonalCell(x:0.5,y:0.5) == nil)
    let tuned = StringSurfaceLayout(fretDivision:.edo53)
    #expect(try JSONDecoder().decode(StringSurfaceLayout.self,from:JSONEncoder().encode(tuned)) == tuned)
    #expect(tuned.continuousCell(x:0.25,y:0.5) == normal.continuousCell(x:0.25,y:0.5))
}
