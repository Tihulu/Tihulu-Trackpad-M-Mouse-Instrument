import Foundation
import Testing
@testable import NoSpeakerCore

private let validScale = "Scale\n2\n700.0\n2"
private let validMap = "0\n48\n72\n60\n60\n440\n2"

@Test func scalaProfileInspectionIdentifiesSourceAndCalibrationStage() throws {
    typealias Profile = ScalaKeyboardProfile
    #expect(Profile.inspectSources(scaleText: "Bad", mappingText: "Bad") == .failure(.source(stage: .scale, reason: .malformed)))
    #expect(Profile.inspectSources(scaleText: "Scale\n2\n700.0\n3", mappingText: validMap) == .failure(.source(stage: .scale, reason: .unsupported)))
    #expect(Profile.inspectSources(scaleText: validScale, mappingText: "Bad") == .failure(.source(stage: .mapping, reason: .malformed)))
    #expect(Profile.inspectSources(scaleText: validScale, mappingText: "0\n48\n72\n60\n60\n440\n3") == .failure(.source(stage: .mapping, reason: .unsupported)))
    let high = "0\n48\n72\n60\n60\n20000\n2"
    #expect(Profile.inspectSources(scaleText: validScale, mappingText: high) == .failure(.source(stage: .calibration, reason: .unsupported)))
    #expect(throws: ScalaKeyboardImport.Failure.unsupported) { try Profile(scaleText: validScale, mappingText: high) }
    let inspected = try Profile.inspectSources(scaleText: validScale, mappingText: validMap).get()
    #expect(inspected == (try Profile(scaleText: validScale, mappingText: validMap)))
}

@Test func scalaProfileInspectionRetainsEnvelopeErrorsAndOriginalBytes() throws {
    typealias Profile = ScalaKeyboardProfile
    func envelope(version: Int, scale: String, mapping: String) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["version": version, "scale": scale, "mapping": mapping])
    }
    let malformed = Data("{}".utf8)
    #expect(Profile.inspectData(malformed) == .failure(.invalidEnvelope))
    #expect(throws: Profile.Failure.invalidEnvelope) { try Profile.importData(malformed) }
    let future = try envelope(version: 2, scale: "Bad", mapping: "Bad")
    #expect(Profile.inspectData(future) == .failure(.unsupportedVersion))
    #expect(throws: Profile.Failure.unsupportedVersion) { try Profile.importData(future) }
    let invalid = try envelope(version: 1, scale: validScale, mapping: "Bad")
    #expect(Profile.inspectData(invalid) == .failure(.source(stage: .mapping, reason: .malformed)))
    #expect(throws: ScalaKeyboardImport.Failure.malformed) { try Profile.importData(invalid) }
    let marked = "\u{FEFF}Échelle\r\n2\r\n700.0\r\n2"
    let data = try envelope(version: 1, scale: marked, mapping: validMap)
    let profile = try Profile.inspectData(data).get()
    #expect(Array(profile.scaleText.utf8) == Array(marked.utf8))
    let roundTrip = try Profile.inspectData(profile.exportData()).get()
    #expect(Array(roundTrip.scaleText.utf8) == Array(marked.utf8))
    #expect(roundTrip.preview == profile.preview)
}
