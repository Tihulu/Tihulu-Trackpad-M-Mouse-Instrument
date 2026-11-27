import Foundation
import Testing
@testable import NoSpeakerCore

private let profileScale = "! preserved\r\nRatios\r\n3\r\n5/4\r\n3/2\r\n2/1\r\n"
private let profileMap = "3\n48\n84\n60\n62\n432.0\n3\n0\nx\n2\n"

@Test func scalaProfileRoundTripPreservesEveryPhysicalDisposition() throws {
    let original = try ScalaKeyboardProfile(scaleText: profileScale, mappingText: profileMap)
    let encoded = try original.exportData()
    let decoded = try ScalaKeyboardProfile.importData(encoded)
    #expect(decoded == original)
    #expect(try decoded.exportData() == encoded)
    for note in 0...127 {
        #expect(decoded.preview.output(note) == original.preview.output(note))
    }
    #expect(decoded.preview.output(61) == .unmapped)
    #expect(decoded.preview.output(47) == .outsideRange)
    guard case .tuned(let pitch) = decoded.preview.output(62) else {
        Issue.record("Reference key must be tuned"); return
    }
    #expect(abs(pitch.frequency - 432) < 1e-8)
}

@Test func scalaProfileRejectsForeignVersionAndUnknownActivationFields() throws {
    let profile = try ScalaKeyboardProfile(scaleText: profileScale, mappingText: profileMap)
    let data = try profile.exportData()
    let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    var changed = object
    changed["version"] = 2
    let future = try JSONSerialization.data(withJSONObject: changed)
    #expect(throws: ScalaKeyboardProfile.Failure.unsupportedVersion) { try ScalaKeyboardProfile.importData(future) }
    for key in ["activate", "deviceID", "allowOutsideScale", "route"] {
        changed = object
        changed[key] = true
        let foreign = try JSONSerialization.data(withJSONObject: changed)
        #expect(throws: ScalaKeyboardProfile.Failure.invalidEnvelope) { try ScalaKeyboardProfile.importData(foreign) }
    }
    changed = object
    changed["version"] = true
    let boolVersion = try JSONSerialization.data(withJSONObject: changed)
    #expect(throws: ScalaKeyboardProfile.Failure.invalidEnvelope) { try ScalaKeyboardProfile.importData(boolVersion) }
}

@Test func scalaProfileRejectsOversizedCorruptAndInvalidPair() throws {
    for data in [Data(), Data("[]".utf8), Data("{}".utf8), Data(repeating: 32, count: ScalaKeyboardProfile.maximumBytes + 1)] {
        #expect(throws: ScalaKeyboardProfile.Failure.invalidEnvelope) { try ScalaKeyboardProfile.importData(data) }
    }
    let mismatched = try JSONSerialization.data(withJSONObject: ["version": 1, "scale": profileScale, "mapping": "0\n0\n127\n60\n60\n440\n12"] as [String: Any])
    #expect(throws: ScalaKeyboardImport.Failure.unsupported) { try ScalaKeyboardProfile.importData(mismatched) }
    let malformed = try JSONSerialization.data(withJSONObject: ["version": 1, "scale": "Bad", "mapping": profileMap] as [String: Any])
    #expect(throws: ScalaKeyboardImport.Failure.malformed) { try ScalaKeyboardProfile.importData(malformed) }
}

@Test func scalaProfileRejectsDuplicateDecodedFieldsInEitherOrder() throws {
    let original = try ScalaKeyboardProfile(scaleText: profileScale, mappingText: profileMap)
    let encoded = try original.exportData()
    let json = try #require(String(data: encoded, encoding: .utf8))
    let prefix = String(json.dropLast())
    let suffix = String(json.dropFirst())
    for raw in [prefix + ",\"version\":2}", "{\"version\":2," + suffix,
                prefix + ",\"\\u0076ersion\":1}", prefix + ",\"scale\":\"bad\"}",
                "{\"\\u0073cale\":\"bad\"," + suffix, prefix + ",\"mapping\":\"bad\"}"] {
        #expect(throws: ScalaKeyboardProfile.Failure.invalidEnvelope) { try ScalaKeyboardProfile.importData(Data(raw.utf8)) }
    }
}

@Test func scalaProfileAcceptsUniqueEscapedKeyAndRejectsForeignShape() throws {
    let original = try ScalaKeyboardProfile(scaleText: "! quoted \"name\" { } : , \\\nRatios\n3\n5/4\n3/2\n2", mappingText: profileMap)
    let data = try original.exportData()
    let json = try #require(String(data: data, encoding: .utf8))
    let escaped = json.replacingOccurrences(of: "\"scale\":", with: "\"\\u0073cale\":")
    #expect(try ScalaKeyboardProfile.importData(Data(escaped.utf8)) == original)
    let spaced = " \t\n" + json + "\r\n"
    #expect(try ScalaKeyboardProfile.importData(Data(spaced.utf8)) == original)
    for raw in [json + " {}", "{\"version\":1,\"scale\":{},\"mapping\":\"x\"}",
                "{\"version\":[1],\"scale\":\"x\",\"mapping\":\"x\"}",
                "{\"version\":1,\"scale\":\"x\",\"mapping\":\"x\",}"] {
        #expect(throws: ScalaKeyboardProfile.Failure.invalidEnvelope) { try ScalaKeyboardProfile.importData(Data(raw.utf8)) }
    }
    let utf16 = try #require(json.data(using: .utf16))
    #expect(throws: ScalaKeyboardProfile.Failure.invalidEnvelope) { try ScalaKeyboardProfile.importData(utf16) }
}
