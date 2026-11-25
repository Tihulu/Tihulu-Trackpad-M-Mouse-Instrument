/// Defensive boundary for the existing private multitouch callback.
/// The contact limit matches the physical Builder mailbox. This validates
/// the envelope, not the lifetime or size of a native pointer.
public enum NativeTouchFramePolicy {
    public static let maximumContacts = 32
    public enum Decision: Sendable, Equatable {
        case ignoreUnknownDevice
        case releaseSurface
        case decode(Int)
    }

    public static func decision(knownDevice:Bool, count:Int, hasData:Bool) -> Decision {
        guard knownDevice else { return .ignoreUnknownDevice }
        guard count > 0, count <= maximumContacts, hasData else { return .releaseSurface }
        return .decode(count)
    }
}
