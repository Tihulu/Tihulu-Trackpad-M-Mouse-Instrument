import Testing
@testable import NoSpeakerCore

@Test func builderDraftSessionRetainsInvalidUnsavedEditsWithoutSaving() {
    let saved = InstrumentPatch.starter
    var draft = saved
    draft.name = ""
    var session = BuilderDraftSession()
    session.remember(draft,saved:saved)
    #expect(session.resume(saved:saved) == draft)
    #expect(saved == .starter)
    session.clear()
    #expect(session.resume(saved:saved) == saved)
}

@Test func builderDraftSessionDoesNotOverwriteNewSavedInstrument() {
    let saved = InstrumentPatch.starter
    var draft = saved
    draft.name = "Unsaved"
    var newer = saved
    newer.name = "Saved elsewhere"
    var session = BuilderDraftSession()
    session.remember(draft,saved:saved)
    #expect(session.resume(saved:newer) == newer)
    #expect(session.resume(saved:saved) == saved)
    session.remember(draft,saved:saved)
    session.remember(saved,saved:saved)
    #expect(session.resume(saved:saved) == saved)
}
