import Testing
@testable import NoSpeakerCore

@Test func physicalKeyboardLegacyScaleKeepsBlackKeyMembershipAndTuning() throws {
    var scale = CustomScale()
    scale.intervals = [0,2,3,5,7,8,10]
    scale.centOffsets = [3:-25,8:15]
    let map = try #require(PhysicalKeyboardScaleMap.legacy(scale,inputRoot:60,outputRoot:60))
    let keys = try #require(map.keyboard(low:60,high:72))
    #expect(keys.filter(\.isMapped).map(\.inputNote) == [60,62,63,65,67,68,70,72])
    #expect(map.key(63)?.pitch?.centsFromRoot == 275)
    #expect(map.key(68)?.pitch?.centsFromRoot == 815)
    #expect(map.key(61)?.pitch == nil)
    #expect(map.key(58)?.pitch?.centsFromRoot == -200)
}
@Test func physicalKeyboard24EDOAcrossAllKeysKeepsQuarterTonesDistinct() throws {
    let t = try #require(MicrotonalKeyboardTuning.edo(24,rootMIDI:60))
    let map = try #require(PhysicalKeyboardScaleMap(tuning:t,inputRoot:60,layout:.allKeys))
    #expect(map.key(60)?.pitch?.centsFromRoot == 0)
    #expect(map.key(61)?.pitch?.centsFromRoot == 50)
    #expect(map.key(62)?.pitch?.centsFromRoot == 100)
    #expect(map.key(72)?.pitch?.centsFromRoot == 600)
    #expect(map.key(84)?.pitch?.centsFromRoot == 1200)
    #expect(map.key(59)?.pitch?.centsFromRoot == -50)
}
@Test func physicalKeyboardWhiteKeysOnlyAndSeparateOutputRoot() throws {
    let t = try #require(MicrotonalKeyboardTuning(degrees:[0,190,350,500,700,850,1050],rootMIDI:62))
    let map = try #require(PhysicalKeyboardScaleMap(tuning:t,inputRoot:60,layout:.whiteKeys))
    #expect(map.key(60)?.pitch?.frequency == t.pitch(step:0)?.frequency)
    #expect(map.key(61)?.pitch == nil)
    #expect(map.key(62)?.pitch?.centsFromRoot == 190)
    #expect(map.key(72)?.pitch?.centsFromRoot == 1200)
    #expect(map.key(59)?.pitch?.centsFromRoot == -150)
    #expect(PhysicalKeyboardScaleMap(tuning:t,inputRoot:61,layout:.whiteKeys) == nil)
}
@Test func physicalKeyboardExplicitQuarterToneSlotsAndInvalidMapping() throws {
    let t = try #require(MicrotonalKeyboardTuning.edo(24,rootMIDI:60))
    let slots:[Int?] = [0,nil,3,nil,7,10,nil,14,nil,17,nil,22]
    let map = try #require(PhysicalKeyboardScaleMap(tuning:t,inputRoot:60,layout:.chromatic(slots)))
    #expect(map.key(62)?.pitch?.centsFromRoot == 150)
    #expect(map.key(64)?.pitch?.centsFromRoot == 350)
    #expect(map.key(72)?.pitch?.centsFromRoot == 1200)
    #expect(map.key(-1) == nil)
    #expect(map.keyboard(low:72,high:60) == nil)
    #expect(PhysicalKeyboardScaleMap(tuning:t,inputRoot:60,layout:.chromatic([0])) == nil)
    var invalid = slots; invalid[2] = 24
    #expect(PhysicalKeyboardScaleMap(tuning:t,inputRoot:60,layout:.chromatic(invalid)) == nil)
    invalid = slots; invalid[4] = 3
    #expect(PhysicalKeyboardScaleMap(tuning:t,inputRoot:60,layout:.chromatic(invalid)) == nil)
}

@Test func physicalKeyboardMemberEncodingPreservesQuarterToneIdentityAndReference() throws {
    let t = try #require(MicrotonalKeyboardTuning.edo(24,rootMIDI:69))
    let map = try #require(PhysicalKeyboardScaleMap(tuning:t,inputRoot:60,layout:.allKeys))
    let zero = try #require(map.memberPitch(60))
    let quarter = try #require(map.memberPitch(61))
    let semitone = try #require(map.memberPitch(62))
    #expect(zero.anchor == 69 && zero.bend == 8192)
    #expect(semitone.anchor == 70 && semitone.bend == 8192)
    #expect(quarter.inputNote != semitone.inputNote && quarter.step != semitone.step)
    let represented = Double(quarter.anchor) + Double(quarter.bend-8192)/Double(quarter.bend>=8192 ? 8191:8192)*2
    #expect(abs(represented-69.5)<0.0003)
    let calibrated = try #require(MicrotonalKeyboardTuning.edo(12,rootMIDI:69,referenceA4:432))
    let calibratedMap = try #require(PhysicalKeyboardScaleMap(tuning:calibrated,inputRoot:60,layout:.allKeys))
    let pitch = try #require(calibratedMap.memberPitch(60))
    #expect(pitch.anchor == 69 && pitch.bend < 8192)
    #expect(map.memberPitch(60,bendRangeSemitones:0) == nil)
}

@Test func physicalKeyboardUnlockPreservesTuningAndOriginalUnassignedKeys() throws {
    var scale=CustomScale()
    scale.intervals=[0,2,4,7,9]
    scale.centOffsets=[2:-25]
    let locked=try #require(PhysicalKeyboardScaleMap.legacy(scale,inputRoot:60,outputRoot:62))
    let unlocked=try #require(PhysicalKeyboardScaleMap.legacy(scale,inputRoot:60,outputRoot:62,allowOutsideScale:true))
    #expect(locked.output(62) == unlocked.output(62))
    #expect(unlocked.key(62)?.pitch?.centsFromRoot == 175)
    #expect(locked.output(61) == .muted)
    #expect(unlocked.output(61) == .originalMIDI(61))
    #expect(unlocked.key(61)?.isMapped == false)
    #expect(unlocked.memberPitch(61) == nil)
    let tuning=try #require(MicrotonalKeyboardTuning.edo(24,rootMIDI:127))
    let map=try #require(PhysicalKeyboardScaleMap(tuning:tuning,inputRoot:60,layout:.allKeys,allowOutsideScale:true))
    #expect(map.output(61) == .unavailable)
    #expect(map.output(-1) == .unavailable)
}

@Test func physicalKeyboardUnlockedMemberOutputSeparatesOriginalAndTunedVoices() throws {
    let tuning=try #require(MicrotonalKeyboardTuning(degrees:[0,175,400,700],rootMIDI:60))
    let slots:[Int?]=[0,nil,1,nil,2,nil,nil,3,nil,nil,nil,nil]
    let map=try #require(PhysicalKeyboardScaleMap(tuning:tuning,inputRoot:60,layout:.chromatic(slots),allowOutsideScale:true))
    #expect(map.memberOutput(61) == .original(inputNote:61,anchor:61,bend:8192,bendRangeSemitones:2))
    let tuned=try #require(map.memberPitch(62))
    #expect(map.memberOutput(62) == .tuned(tuned))
    #expect(tuned.bend != 8192)
    #expect(map.memberOutput(61,bendRangeSemitones:0) == .unavailable)
    #expect(map.memberOutput(128) == .unavailable)
    let locked=try #require(PhysicalKeyboardScaleMap(tuning:tuning,inputRoot:60,layout:.chromatic(slots)))
    #expect(locked.memberOutput(61) == .muted)
    #expect(locked.memberOutput(62) == map.memberOutput(62))
}
