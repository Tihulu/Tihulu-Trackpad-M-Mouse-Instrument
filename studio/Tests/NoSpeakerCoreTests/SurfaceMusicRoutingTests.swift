import Testing
@testable import NoSpeakerCore

@Test func gmDrumPadsUseChannelTenAndRealPercussionNotes() {
    #expect(GMDrumPads.midiChannel == 9)
    #expect(GMDrumPads.standard[0].midiNote == 36)
    #expect(GMDrumPads.standard[1].midiNote == 38)
    #expect(GMDrumPads.standard[2].midiNote == 42)
    #expect(GMDrumPads.standard[3].midiNote == 46)
    #expect(GMDrumPads.name(for: 39) == "Clap")
}

@Test func gmDrumPadLayoutsHaveExpectedLengths() {
    #expect(DrumPadLayout.compact8.pads.count == 8)
    #expect(DrumPadLayout.standard12.pads.count == 12)
    #expect(DrumPadLayout.extended16.pads.count == 16)
}

@Test func drumPadCoordinatesClampToValidZones() {
    #expect(GMDrumPads.pad(forNormalizedX: -2, layout: .compact8).midiNote == 36)
    #expect(GMDrumPads.pad(forNormalizedX: 0.2499, layout: .compact8).midiNote == 38)
    #expect(GMDrumPads.pad(forNormalizedX: 0.25, layout: .compact8).midiNote == 42)
    #expect(GMDrumPads.pad(forNormalizedX: 1, layout: .compact8).midiNote == 47)
    #expect(GMDrumPads.pad(forNormalizedX: 10, layout: .standard12).midiNote == 56)
    #expect(GMDrumPads.pad(forNormalizedX: .nan, layout: .standard12).midiNote == 36)
}

@Test func independentSurfaceOutputDestinations() {
    #expect(SurfaceOutputRoute.trackpadHaptic.sendsHaptics)
    #expect(!SurfaceOutputRoute.trackpadHaptic.sendsMIDI)
    #expect(SurfaceOutputRoute.midiInstrument.sendsMIDI)
    #expect(!SurfaceOutputRoute.midiInstrument.sendsHaptics)
    #expect(SurfaceOutputRoute.both.sendsMIDI)
    #expect(SurfaceOutputRoute.both.sendsHaptics)
}

@Test func touchDrumsReuseSequencerAndHaveDistinctSafeProfiles() throws {
    let pairs: [(Int, DrumVoice)] = [(36, .kick), (38, .snare), (42, .closedHat), (46, .openHat), (39, .clap), (47, .tom)]
    for (note, voice) in pairs {
        #expect(HapticPatternRenderer.drumFrame(midiNote: note, velocity: 0.8) == HapticPatternRenderer.drumFrame(voice, velocity: 0.8))
    }
    let frames = try GMDrumPads.standard.map { pad in
        try #require(HapticPatternRenderer.drumFrame(midiNote: pad.midiNote, velocity: 0.8))
    }
    for (index, frame) in frames.enumerated() {
        #expect(HapticSafetyPolicy().clamp(frame) == frame)
        for other in frames.dropFirst(index + 1) {
            #expect(frame != other)
        }
    }
    #expect(HapticPatternRenderer.drumFrame(midiNote: 0, velocity: 0.8) == nil)
}
