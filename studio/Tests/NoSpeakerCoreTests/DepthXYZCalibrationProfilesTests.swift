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

extension DepthXYZCalibrationProfilesTests {
    @Test func malformedHybridRoleCannotBeRestored() throws {
        var library = DepthXYZCalibrationProfiles()
        try library.save(name: "Hybrid", volume: .init(), axisMask: 5, pitchAxis: .z, hybrid: true)
        let bytes = try JSONEncoder().encode(library)
        #expect(try JSONDecoder().decode(DepthXYZCalibrationProfiles.self, from: bytes) == library)
        var root = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        var records = try #require(root["profiles"] as? [[String: Any]])
        records[0].removeValue(forKey: "pitchAxis")
        root["profiles"] = records
        let invalid = try JSONSerialization.data(withJSONObject: root)
        #expect(throws: DepthXYZCalibrationProfiles.Failure.invalidSettings) {
            _ = try JSONDecoder().decode(DepthXYZCalibrationProfiles.self, from: invalid)
        }
        records[0]["pitchAxis"] = "z"
        records[0]["name"] = " Hybrid "
        root["profiles"] = records
        let noncanonical = try JSONSerialization.data(withJSONObject: root)
        #expect(throws: DepthXYZCalibrationProfiles.Failure.invalidName) {
            _ = try JSONDecoder().decode(DepthXYZCalibrationProfiles.self, from: noncanonical)
        }
    }
}

extension DepthXYZCalibrationProfilesTests {
    @Test func replacementPreservesIdentityAndRejectsStaleOrInvalidChanges() throws {
        var library = DepthXYZCalibrationProfiles()
        try library.save(name: "Desk", volume: .init(), axisMask: 7)
        try library.save(name: "Stage", volume: .init(), axisMask: 3)
        let old = library.profiles[0]
        let other = library.profiles[1]
        let volume = DepthXYZVolume(nearMeters: 0.3, farMeters: 1.2)
        try library.replace(expected: old, volume: volume, axisMask: 5, pitchAxis: .z, hybrid: true)
        #expect(library.profiles.count == 2)
        #expect(library.profiles[0].name == old.name)
        #expect(library.profiles[0].volume == volume)
        #expect(library.profiles[0].hybrid == true)
        #expect(library.profiles[1] == other)
        let updated = library
        #expect(throws: DepthXYZCalibrationProfiles.Failure.changed) {
            try library.replace(expected: old, volume: .init(), axisMask: 7)
        }
        #expect(throws: DepthXYZCalibrationProfiles.Failure.invalidSettings) {
            try library.replace(expected: updated.profiles[0], volume: .init(), axisMask: 0)
        }
        #expect(library == updated)
    }
}
