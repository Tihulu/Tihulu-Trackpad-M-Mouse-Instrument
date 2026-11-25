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


/// Inventory evidence is independent of contact cadence. A motionless
/// held finger is never itself evidence of device loss.
public struct NativeSurfaceInventoryGuard: Sendable {
    public enum Verdict: Equatable, Sendable {
        case healthy, suspect, lost(Set<UInt64>), unavailable
    }
    private var misses:[UInt64:Int] = [:]
    private var unknown = 0
    public init() {}
    public mutating func observe(expected:Set<UInt64>,available:Set<UInt64>?) -> Verdict {
        guard !expected.isEmpty else { misses.removeAll(); unknown = 0; return .healthy }
        guard let available else {
            misses.removeAll()
            unknown = min(3,unknown+1)
            return unknown >= 3 ? .unavailable : .suspect
        }
        unknown = 0
        let missing = expected.subtracting(available)
        misses = Dictionary(uniqueKeysWithValues:missing.map { ($0,min(2,(misses[$0] ?? 0)+1)) })
        let lost = Set(misses.filter { $0.value >= 2 }.keys)
        if !lost.isEmpty { return .lost(lost) }
        return missing.isEmpty ? .healthy : .suspect
    }
}

/// Explicitly requested routes are all-or-nothing at start. An absent
/// inventory is not evidence of an available surface.
public enum NativeSurfaceAdmission {
    public static func missing<Surface:Hashable>(required:Set<Surface>,registered:Set<Surface>?) -> Set<Surface> {
        required.subtracting(registered ?? [])
    }
}
