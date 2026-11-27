import Testing
@testable import NoSpeakerCore

@Test func scalaPreviewDistinguishesUnmappedRangeAndInvalidNotes() throws {
    let scale = try ScalaKeyboardImport.scale("Test\n3\n100.0\n700.0\n2")
    let map = try ScalaKeyboardImport.mapping("3\n48\n84\n60\n60\n440\n3\n0\nx\n2", scale: scale)
    let preview = try ScalaKeyboardPreview(scale: scale, mapping: map)
    #expect(preview.output(61) == .unmapped)
    #expect(preview.output(47) == .outsideRange)
    #expect(preview.output(85) == .outsideRange)
    #expect(preview.output(Int.max) == .unavailable)
    #expect(preview.output(Int.min) == .unavailable)
    #expect(preview.output(62) == .tuned(try #require(preview.tuning.pitch(step: 2))))
}

@Test func scalaPreviewNeverFallsBackForAssignedOutOfDomainPitch() throws {
    let scale = try ScalaKeyboardImport.scale("Wide\n2\n700.0\n2")
    let map = try ScalaKeyboardImport.mapping("0\n0\n127\n60\n60\n440\n2", scale: scale)
    let preview = try ScalaKeyboardPreview(scale: scale, mapping: map)
    #expect(map.step(127) == 67)
    #expect(preview.output(127) == .unavailable)
    #expect(map.step(0) == -60)
    #expect(preview.output(0) == .unavailable)
    #expect(preview.output(60) == .tuned(try #require(preview.tuning.pitch(step: 0))))
}
