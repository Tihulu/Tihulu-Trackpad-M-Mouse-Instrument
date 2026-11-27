import Foundation
import Testing
@testable import NoSpeakerCore

@Test func scalaRejectsHiddenLineSeparatorsInsteadOfInterpretingFields() throws {
    let scale = try ScalaKeyboardImport.scale("Scale\n2\n100.0\n2")
    for separator in ["\u{000B}", "\u{000C}", "\u{0085}", "\u{2028}", "\u{2029}"] {
        let source = ["Scale", "2", "100.0", "2"].joined(separator: separator)
        let mapping = ["0", "48", "72", "60", "60", "440", "2"].joined(separator: separator)
        #expect(throws: ScalaKeyboardImport.Failure.malformed) { try ScalaKeyboardImport.scale(source) }
        #expect(throws: ScalaKeyboardImport.Failure.malformed) { try ScalaKeyboardImport.mapping(mapping, scale: scale) }
    }
}

@Test func scalaPhysicalLineEndingsPreserveCanonicalMapping() throws {
    let source = ["Scale", "2", "100.0 label", "2"]
    let mapping = ["2", "48", "72", "60", "60", "440", "2", "0", "x"]
    let canonical = try ScalaKeyboardProfile(scaleText: source.joined(separator: "\n"), mappingText: mapping.joined(separator: "\n"))
    for separator in ["\r", "\n", "\r\n"] {
        let text = source.joined(separator: separator)
        let map = mapping.joined(separator: separator)
        let profile = try ScalaKeyboardProfile(scaleText: text, mappingText: map)
        #expect(profile.preview == canonical.preview)
        #expect(Array(profile.scaleText.utf8) == Array(text.utf8))
        #expect(Array(profile.mappingText.utf8) == Array(map.utf8))
    }
}
