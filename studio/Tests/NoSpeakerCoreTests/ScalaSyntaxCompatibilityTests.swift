import Foundation
import Testing
@testable import NoSpeakerCore

@Test func scalaPitchLabelsDoNotChangeNumericInterpretation() throws {
    let canonical = try ScalaKeyboardImport.scale("Labels\n3\n5/4\n700.0\n2")
    let labelled = try ScalaKeyboardImport.scale("Labels\n3\n5/4\tE. third\n700.0  G\n2  octave.")
    #expect(labelled == canonical)
}

@Test func scalaZeroFormalOctaveResolvesToScaleLength() throws {
    let scale = try ScalaKeyboardImport.scale("Three\n3\n100.0\n700.0\n2")
    for prefix in ["0\n48\n72\n60\n60\n440\n", "3\n48\n72\n60\n60\n440\n"] {
        let suffix = prefix.hasPrefix("3") ? "\n0\nx\n2" : ""
        let explicit = try ScalaKeyboardImport.mapping(prefix + "3" + suffix, scale: scale)
        let implicit = try ScalaKeyboardImport.mapping(prefix + "0" + suffix, scale: scale)
        #expect(explicit == implicit)
        #expect(try ScalaKeyboardImport.tuning(scale: scale, mapping: explicit) == ScalaKeyboardImport.tuning(scale: scale, mapping: implicit))
    }
}

@Test func scalaOmittedTrailingMapSlotsAreHolesNotShorterPeriods() throws {
    let source = "Three\n3\n100.0\n700.0\n2"
    let prefix = "4\n48\n72\n60\n60\n440\n3\n0\n2"
    let explicit = try ScalaKeyboardProfile(scaleText: source, mappingText: prefix + "\nx\nx")
    let omitted = try ScalaKeyboardProfile(scaleText: source, mappingText: prefix)
    #expect(omitted.preview == explicit.preview)
    #expect(omitted.preview.mapping.entries == [0, 2, nil, nil])
    #expect(omitted.preview.mapping.step(56) == -3)
    #expect(omitted.preview.mapping.step(59) == nil)
    #expect(omitted.preview.mapping.step(62) == nil)
    #expect(omitted.preview.mapping.step(64) == 3)
    #expect(try ScalaKeyboardProfile.importData(omitted.exportData()) == omitted)
}

@Test func scalaSyntaxExtensionsPreserveMalformedAndUnsupportedBoundaries() throws {
    let scale = try ScalaKeyboardImport.scale("Three\n3\n100.0\n700.0\n2")
    for text in ["Bad\n2\n1/0 label\n2", "Bad\n2\n100.0oops label\n2", "Bad\n2\n100.0 label\n3/1", "Bad\n2\n100.0\u{FEFF} label\n2", "Bad\n2\n100.0 label\n2\nextra"] {
        #expect(throws: ScalaKeyboardImport.Failure.self) { try ScalaKeyboardImport.scale(text) }
    }
    for mapping in ["4\n48\n72\n60\n62\n440\n0\n0\n2", "2\n48\n72\n60\n60\n440\n0\n0\n2\nx", "2\n48\n72\n60\n60\n440\n2\n0\n1", "0\n48\n72\n60\n60\n440\n0\n0", "3\n48\n72\n60\n60\n440\n0"] {
        #expect(throws: ScalaKeyboardImport.Failure.self) { try ScalaKeyboardImport.mapping(mapping, scale: scale) }
    }
}
