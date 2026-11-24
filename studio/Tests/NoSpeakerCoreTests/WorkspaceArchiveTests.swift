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
