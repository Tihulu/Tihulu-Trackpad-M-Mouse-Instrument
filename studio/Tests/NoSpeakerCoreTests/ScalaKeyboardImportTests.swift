import Foundation
import Testing
@testable import NoSpeakerCore

private let just = "! fixture\r\nJust scale\r\n3\r\n5/4 ! third\r\n3/2\r\n2\r\n"
private let kbm = "3\n48\n84\n60\n64\n432.0\n3\n0\nx\n2\n"

@Test func scalaRatioAndDecimalKeepDistinctDegrees() throws {
    let scale = try ScalaKeyboardImport.scale(just)
    #expect(scale.name == "Just scale")
    #expect(scale.degrees.count == 3)
    #expect(abs(scale.degrees[1] - 386.3137138648348) < 1e-10)
    #expect(abs(scale.degrees[2] - 701.9550008653874) < 1e-10)
    let quarter = try ScalaKeyboardImport.scale("Quarter\n3\n50.0\n100.0\n1200.0")
    #expect(quarter.degrees == [0, 50, 100])
}

@Test func scalaRejectsMalformedAndUnsupportedInputs() {
    for text in ["bad\n2\n1/0\n2", "bad\n2\n0.0\n2", "bad\n3\n100.0\n100.0\n2",
                 "bad\n2\n100.0", "bad\n2\n100.0\n2\nextra", "bad\n2\n100.0\n3/1",
                 "bad\n129", "bad\n2\nNaN\n2", "bad\n2\n1e2\n2", "bad\n2\n1000000001/1\n2",
                 String(repeating: "!", count: 16_385)] {
        #expect(throws: ScalaKeyboardImport.Failure.self) { try ScalaKeyboardImport.scale(text) }
    }
}

@Test func scalaMappingPreservesHolesAndNegativeSteps() throws {
    let scale = try ScalaKeyboardImport.scale(just)
    let map = try ScalaKeyboardImport.mapping(kbm.replacingOccurrences(of: "\n64\n", with: "\n62\n"), scale: scale)
    #expect(map.step(60) == 0)
    #expect(map.step(61) == nil)
    #expect(map.step(62) == 2)
    #expect(map.step(59) == -1)
    #expect(map.step(57) == -3)
    #expect(map.step(47) == nil)
    #expect(map.step(85) == nil)
    let tuning = try ScalaKeyboardImport.tuning(scale: scale, mapping: map)
    let reference = try #require(tuning.pitch(step: 2))
    #expect(abs(reference.frequency - 432) < 1e-8)
    let root = try #require(tuning.pitch(step: 0))
    #expect(abs(root.frequency - 288) < 1e-8)
}

@Test func scalaLinearMappingCalibratesNonMiddleReference() throws {
    let scale = try ScalaKeyboardImport.scale("Quarter\n3\n50.0\n100.0\n2")
    let map = try ScalaKeyboardImport.mapping("0\n0\n127\n60\n62\n440\n3", scale: scale)
    #expect(map.step(59) == -1)
    #expect(map.step(63) == 3)
    let tuning = try ScalaKeyboardImport.tuning(scale: scale, mapping: map)
    let p = try #require(tuning.pitch(step: 2))
    #expect(abs(p.frequency - 440) < 1e-8)
    #expect(tuning.pitch(step: 0)?.frequency != tuning.pitch(step: 1)?.frequency)
}

@Test func scalaMappingRejectsInvalidReferenceBoundsAndUnsupportedPeriod() throws {
    let scale = try ScalaKeyboardImport.scale(just)
    for text in [kbm, "0\n0\n127\n60\n69\n440\n0", "0\n80\n60\n60\n69\n440\n3",
                 "0\n0\n128\n60\n69\n440\n3", "0\n0\n127\n60\n69\ninf\n3",
                 "1\n0\n127\n60\n60\n440\n3\n3", "1\n0\n127\n60\n60\n440\n3\nx",
                 "129\n0\n127\n60\n60\n440\n3"] {
        #expect(throws: ScalaKeyboardImport.Failure.self) { try ScalaKeyboardImport.mapping(text, scale: scale) }
    }
    let high = try ScalaKeyboardImport.mapping("0\n0\n127\n60\n60\n20000\n3", scale: scale)
    #expect(throws: ScalaKeyboardImport.Failure.self) { try ScalaKeyboardImport.tuning(scale: scale, mapping: high) }
}

@Test func scalaImportAcceptsOneLeadingUTF8BOMWithoutChangingPitchOrMapping() throws {
    let source = "! comment\nBOM test\n3\n100.0\n700.0\n2/1\n"
    let mapping = "! comment\n3\n48\n84\n60\n60\n440\n3\n0\nx\n2\n"
    let plain = try ScalaKeyboardProfile(scaleText: source, mappingText: mapping)
    let marked = try ScalaKeyboardProfile(scaleText: "\u{FEFF}" + source, mappingText: "\u{FEFF}" + mapping)
    #expect(marked.preview == plain.preview)
    #expect(marked.scaleText == "\u{FEFF}" + source)
    #expect(try ScalaKeyboardProfile.importData(marked.exportData()) == marked)
    let noComments = "0\n0\n127\n60\n60\n440\n3"
    let scale = try ScalaKeyboardImport.scale(source)
    #expect(try ScalaKeyboardImport.mapping("\u{FEFF}" + noComments, scale: scale) == ScalaKeyboardImport.mapping(noComments, scale: scale))
}

@Test func scalaImportRejectsRepeatedOrMisplacedEncodingMarker() throws {
    let scaleText = "Name\n2\n100.0\n2"
    let scale = try ScalaKeyboardImport.scale(scaleText)
    for text in ["\u{FEFF}\u{FEFF}" + scaleText, "Name\n\u{FEFF}2\n100.0\n2"] {
        #expect(throws: ScalaKeyboardImport.Failure.malformed) { try ScalaKeyboardImport.scale(text) }
    }
    for text in ["\u{FEFF}\u{FEFF}0\n0\n127\n60\n60\n440\n2", "0\n0\n127\n60\n60\n\u{FEFF}440\n2"] {
        #expect(throws: ScalaKeyboardImport.Failure.malformed) { try ScalaKeyboardImport.mapping(text, scale: scale) }
    }
}
