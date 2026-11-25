import Foundation

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
    private var unverified:[UInt64:Int] = [:]
    private var unknown = 0
    public init() {}
    public mutating func observe(expected:Set<UInt64>,available:Set<UInt64>?) -> Verdict {
        guard !expected.isEmpty else {
            misses.removeAll();unverified.removeAll();unknown=0;return .healthy
        }
        // Mixed missing/nil observations must not keep a disappeared device
        // alive indefinitely by resetting each other's consecutive counters.
        // Only positive inventory evidence clears this per-device budget.
        let unconfirmed=expected.subtracting(available ?? [])
        unverified=Dictionary(uniqueKeysWithValues:unconfirmed.map { ($0,min(4,(unverified[$0] ?? 0)+1)) })
        let mixedExpired=unverified.values.contains { $0>=4 }
        guard let available else {
            misses.removeAll()
            unknown = min(3,unknown+1)
            return unknown >= 3 || mixedExpired ? .unavailable : .suspect
        }
        unknown = 0
        let missing = expected.subtracting(available)
        misses = Dictionary(uniqueKeysWithValues:missing.map { ($0,min(2,(misses[$0] ?? 0)+1)) })
        let lost = Set(misses.filter { $0.value >= 2 }.keys)
        if !lost.isEmpty { return .lost(lost) }
        if mixedExpired { return .unavailable }
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


/// Process-wide nonwaiting admission for private inventory calls. A stalled
/// worker cannot cause an unbounded queue of subsequent native enumerations.
public final class NativeInventoryReadGate: @unchecked Sendable {
    private let lock=NSLock()
    private var active:UUID?
    public init() {}
    public func tryBegin()->UUID? {
        lock.lock();defer { lock.unlock() }
        guard active == nil else { return nil }
        let token=UUID();active=token;return token
    }
    public func finish(_ token:UUID) {
        lock.lock();defer { lock.unlock() }
        if active==token { active=nil }
    }
}

/// One result slot owned by a single monitor generation. No asynchronous
/// waiter is required; missing results are evidence of unavailable inventory.
public final class NativeInventoryResultSlot<Value:Sendable>: @unchecked Sendable {
    private let lock=NSLock()
    private var result:Value?
    public init() {}
    public func publish(_ value:Value) {
        lock.lock();defer { lock.unlock() };result=value
    }
    public func take()->Value? {
        lock.lock();defer { lock.unlock() }
        let value=result;result=nil;return value
    }
}
