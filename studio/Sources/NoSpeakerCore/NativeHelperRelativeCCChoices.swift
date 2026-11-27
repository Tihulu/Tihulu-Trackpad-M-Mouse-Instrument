/// Relative-only picker policy: preserve the existing Absolute Helper choices.
/// A disabled other lane must not remove any available controller.
public enum NativeHelperRelativeCCChoices {
    public static func choices(channel: Int, otherEnabledCC: Int? = nil) -> [Int] {
        HelperCCPolicy.choices.filter { cc in
            cc != otherEnabledCC && ContinuousResponse.permitsRelative(
                .init(.controlChange, channel: channel, number: cc))
        }
    }
}
