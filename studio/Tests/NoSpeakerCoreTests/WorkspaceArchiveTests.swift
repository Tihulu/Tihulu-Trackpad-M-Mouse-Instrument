import Foundation
import Testing
@testable import NoSpeakerCore

private struct Fixture: Codable, Equatable {
    var notes: [Int]
    var bpm: Double
}

@Test func workspaceArchiveRoundTrip() throws {
    let payload = Fixture(notes: [60, 64, 67], bpm: 120)
    let data = try WorkspaceArchive.encode(name: "Studio", payload: payload)
    let decoded = try WorkspaceArchive.decode(Fixture.self, from: data)
    #expect(decoded.name == "Studio")
    #expect(decoded.version == 1)
    #expect(decoded.payload == payload)
}

@Test func workspaceArchiveRejectsOversizeAndInvalidName() {
    #expect(throws: WorkspaceArchiveError.tooLarge) {
        try WorkspaceArchive.decode(Fixture.self, from: Data(repeating: 0, count: WorkspaceArchive.maximumBytes + 1))
    }
    #expect(throws: WorkspaceArchiveError.invalidName) {
        try WorkspaceArchive.encode(name: " ", payload: Fixture(notes: [], bpm: 120))
    }
}

@Test func workspaceArchiveRejectsUnknownVersionAndFormat() throws {
    let data = try WorkspaceArchive.encode(name: "Test", payload: Fixture(notes: [], bpm: 120))
    var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    object["version"] = 99
    let future = try JSONSerialization.data(withJSONObject: object)
    #expect(throws: WorkspaceArchiveError.unsupportedVersion) {
        try WorkspaceArchive.decode(Fixture.self, from: future)
    }
    object["version"] = 1
    object["format"] = "unrelated"
    let foreign = try JSONSerialization.data(withJSONObject: object)
    #expect(throws: WorkspaceArchiveError.unsupportedVersion) {
        try WorkspaceArchive.decode(Fixture.self, from: foreign)
    }
}


@Test func workspaceFileImportReadsCompleteBoundedFileAndRejectsOversize() throws {
    let dir=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString,isDirectory:true)
    try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true)
    defer { try? FileManager.default.removeItem(at:dir) }
    let url=dir.appendingPathComponent("layout.json")
    for count in [0,1,65537,WorkspaceArchive.maximumBytes] {
        let bytes=Data(repeating:42,count:count)
        try bytes.write(to:url)
        #expect(try WorkspaceArchive.readFile(at:url)==bytes)
    }
    try Data(repeating:42,count:WorkspaceArchive.maximumBytes+1).write(to:url)
    #expect(throws:WorkspaceArchiveError.tooLarge) { try WorkspaceArchive.readFile(at:url) }
    #expect(throws:CocoaError.self) { try WorkspaceArchive.readFile(at:dir) }
    let remote=try #require(URL(string:"https://example.invalid/layout.json"))
    #expect(throws:CocoaError.self) { try WorkspaceArchive.readFile(at:remote) }
}
