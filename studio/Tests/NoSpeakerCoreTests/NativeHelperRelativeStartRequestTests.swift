import Testing
@testable import NoSpeakerCore

private typealias Request = NativeHelperRelativeStartRequest
private typealias Axis = NativeHelperRelativeClutch.Axis

@Test func relativeStartRequestChecksFirstManualModeWithoutImplicitRemapping() {
    let axes: [Axis] = [.x, .y, .contactSize]
    let channels = [Int.min, 0, 1, 16, 17, Int.max]
    let surfaces: [Request.Surface?] = [nil, .trackpad, .magicMouse]
    for surface in surfaces {
        for mask in 0..<8 {
            let enabled = Set(axes.enumerated().compactMap { (mask & (1 << $0.offset)) != 0 ? $0.element : nil })
            for bits in 0..<16 {
                let daw = bits & 1 != 0, pedal = bits & 2 != 0
                let share = bits & 4 != 0, rpn = bits & 8 != 0
                for channel in channels {
                    for validSettings in [false, true] {
                        var settings = NativeHelperRelativeManualSettings()
                        if !validSettings { settings.x.reference = .nan }
                        let expected: Request.Failure?
                        if surface == nil { expected = .singleSurfaceRequired }
                        else if !daw { expected = .midiOutputRequired }
                        else if mask == 0 { expected = .expressiveAxisRequired }
                        else if pedal && !share { expected = .pedalSharingRequired }
                        else if mask & 1 != 0 && rpn { expected = .automaticBendRangeUnsupported }
                        else if channel < 1 || channel > 16 { expected = .channelOutOfRange }
                        else if !validSettings { expected = .invalidManualSettings }
                        else { expected = nil }
                        let result = Request.resolve(selectedSurface: surface, orientation: .vertical,
                            sendToDAW: daw, enabled: enabled, selectedSurfaceUsesSustain: pedal,
                            sharePedalSurface: share, configureReceiverBendRange: rpn,
                            oneBasedChannel: channel, vibratoCC: 1, expressionCC: 11, settings: settings)
                        switch result {
                        case .failure(let reason): #expect(reason == expected)
                        case .success(let request):
                            #expect(expected == nil)
                            #expect(request.surface == surface)
                            #expect(request.orientation == .vertical)
                            #expect(request.output.channel == channel - 1)
                            #expect(Set(request.output.configuration.lanes.keys) == enabled)
                            #expect(request.output.configuration.plan.targetDestinations.count == enabled.count)
                        }
                    }
                }
            }
        }
    }
}

@Test(arguments: Array(1...16))
func relativeStartRequestMatchesPickerAndFactory(channel: Int) {
    let settings = NativeHelperRelativeManualSettings()
    let choices = NativeHelperRelativeCCChoices.choices(channel: channel - 1)
    for cc in -1...128 {
        for axis: Axis in [.y, .contactSize] {
            let result = Request.resolve(selectedSurface: .magicMouse, orientation: .horizontal,
                sendToDAW: true, enabled: [axis], selectedSurfaceUsesSustain: false,
                sharePedalSurface: false, configureReceiverBendRange: true,
                oneBasedChannel: channel, vibratoCC: axis == .y ? cc : Int.min,
                expressionCC: axis == .contactSize ? cc : Int.max, settings: settings)
            switch result {
            case .success(let request):
                #expect(choices.contains(cc))
                #expect(request.output.configuration.plan.targetDestinations == [.init(.controlChange, channel: channel - 1, number: cc)])
            case .failure(let reason):
                #expect(!choices.contains(cc))
                #expect(reason == .invalidExpressiveTargets)
            }
        }
    }
    let duplicate = Request.resolve(selectedSurface: .trackpad, orientation: .horizontal,
        sendToDAW: true, enabled: [.y, .contactSize], selectedSurfaceUsesSustain: true,
        sharePedalSurface: true, configureReceiverBendRange: false, oneBasedChannel: channel,
        vibratoCC: 1, expressionCC: 1, settings: settings)
    switch duplicate {
    case .success: Issue.record("Duplicate enabled CCs must not be remapped")
    case .failure(let reason): #expect(reason == .invalidExpressiveTargets)
    }
}
