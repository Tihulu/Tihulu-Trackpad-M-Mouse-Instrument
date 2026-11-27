import Testing
@testable import NoSpeakerCore

@Test(arguments: Array(-1...16))
func relativePickerMatchesManualConfiguration(channel: Int) {
    let settings = NativeHelperRelativeManualSettings()
    let absolute = HelperCCPolicy.choices
    let available = NativeHelperRelativeCCChoices.choices(channel: channel)
    #expect(available.count == ((0...15).contains(channel) ? 104 : 0))
    for cc in -1...128 {
        let singleY = NativeHelperRelativeSingleChannel(settings: settings, enabled: [.y], channel: channel, vibratoCC: cc, expressionCC: -1)
        let singleSize = NativeHelperRelativeSingleChannel(settings: settings, enabled: [.contactSize], channel: channel, vibratoCC: -1, expressionCC: cc)
        #expect((singleY != nil) == available.contains(cc))
        #expect((singleSize != nil) == available.contains(cc))
    }
    for other in -1...128 {
        let choices = NativeHelperRelativeCCChoices.choices(channel: channel, otherEnabledCC: other)
        #expect(choices == available.filter { $0 != other })
        for cc in -1...128 {
            let config = NativeHelperRelativeSingleChannel(settings: settings, enabled: [.x, .y, .contactSize], channel: channel, vibratoCC: cc, expressionCC: other)
            let expected = available.contains(other) && choices.contains(cc)
            #expect((config != nil) == expected)
        }
    }
    #expect(HelperCCPolicy.choices == absolute)
}
