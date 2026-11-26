import Foundation
import Testing
import NoSpeakerCore

struct DepthXYZCalibrationProfilesTests {
    @Test func localVolumesPersistIndependentlyOfAxisAndHostSettings() throws {
        var profiles = DepthXYZCalibrationProfiles()
        var narrow = DepthXYZVolume()
        narrow.nearMeters = 0.4
        try profiles.save(name: " Stage A ", volume: narrow, axisMask: 5)
        try profiles.save(name: "Stage B", volume: DepthXYZVolume(), axisMask: 7)
        let data = try JSONEncoder().encode(profiles)
        var restored = try JSONDecoder().decode(DepthXYZCalibrationProfiles.self, from: data)
        #expect(restored == profiles)
        restored.remove(id: "stage b")
        #expect(restored.profiles.count == 1)
        #expect(restored.profiles.first?.name == "Stage A")
        #expect(restored.profiles.first?.axisMask == 5)
        #expect(restored.profiles.first?.volume == narrow)
    }

    @Test func invalidOrCollidingCalibrationsCannotReplaceSavedSettings() throws {
        var library = DepthXYZCalibrationProfiles()
        let volume = DepthXYZVolume()
        try library.save(name: "Desk", volume: volume, axisMask: 7)
        #expect(throws: DepthXYZCalibrationProfiles.Failure.duplicate) {
            try library.save(name: " desk ", volume: volume, axisMask: 1)
        }
        #expect(throws: DepthXYZCalibrationProfiles.Failure.invalidSettings) {
            try library.save(name: "Zero axes", volume: volume, axisMask: 0)
        }
        var invalid = volume
        invalid.top = invalid.bottom
        #expect(throws: DepthXYZCalibrationProfiles.Failure.invalidSettings) {
            try library.save(name: "Flat", volume: invalid, axisMask: 7)
        }
        #expect(library.profiles.count == 1)
        let bytes = try JSONEncoder().encode(library)
        var document = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        var record = try #require((document["profiles"] as? [[String: Any]])?.first)
        record["axisMask"] = 16
        document["profiles"] = [record]
        let malformed = try JSONSerialization.data(withJSONObject: document)
        #expect(throws: DepthXYZCalibrationProfiles.Failure.invalidSettings) {
            _ = try JSONDecoder().decode(DepthXYZCalibrationProfiles.self, from: malformed)
        }
    }
}
