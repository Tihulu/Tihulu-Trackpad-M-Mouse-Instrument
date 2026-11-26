/// Outgoing CC64 owners on one shared MIDI endpoint. Releases are scoped:
/// another owner holding the same channel keeps that pedal active.
public struct LegacySustainOwners: Sendable {
    public enum Owner: Hashable, Sendable { case touch, helper, touchBar }
    private var owners: [Owner:Set<Int>] = [:]
    public init() {}
    public func channels(for owner: Owner) -> Set<Int> { owners[owner] ?? [] }
    public var active: Set<Int> { owners.values.reduce(into:Set<Int>()) { $0.formUnion($1) } }

    public mutating func replace(_ owner: Owner, channels: Set<Int>) -> [SensorCommand] {
        replaceFrame([owner:channels])
    }

    /// Commit all admitted owners of one input frame before calculating
    /// wire transitions. An omitted owner is unchanged, not released.
    public mutating func replaceFrame(_ updates: [Owner:Set<Int>]) -> [SensorCommand] {
        let before = active
        for (owner,channels) in updates {
            let valid = channels.filter { (0...15).contains($0) }
            if valid.isEmpty { owners.removeValue(forKey:owner) }
            else { owners[owner] = valid }
        }
        let after = active
        return before.subtracting(after).sorted().map { .init(.init(.sustain,channel:$0),value:0) }
            + after.subtracting(before).sorted().map { .init(.init(.sustain,channel:$0),value:127) }
    }
    /// Apply a physical frame one channel at a time. Release-only changes
    /// are cleanup; additions (even silent shared-gate joins) require a
    /// fresh receipt. Changes for the same channel are atomic, so a fresh
    /// handoff cannot pulse CC64. Unadmitted additions never become owners.
    /// The caller retires the physical session if admission fails.
    public mutating func replaceFrameAdmitted(_ updates:[Owner:Set<Int>],
                                               permits:()->Bool,
                                               send:(SensorCommand)->Void)->Bool {
        let valid=updates.mapValues { Set($0.filter { (0...15).contains($0) }) }
        let channels=Set(valid.keys.flatMap { owner in
            self.channels(for:owner).union(valid[owner] ?? [])
        })
        let additions=Set(channels.filter { channel in
            valid.contains { owner,desired in
                desired.contains(channel) && !self.channels(for:owner).contains(channel)
            }
        })
        let ordered=channels.subtracting(additions).sorted()+additions.sorted()
        for channel in ordered {
            if additions.contains(channel),!permits() { return false }
            var change:[Owner:Set<Int>]=[:]
            for (owner,desired) in valid {
                var next=self.channels(for:owner)
                if desired.contains(channel) { next.insert(channel) }
                else { next.remove(channel) }
                change[owner]=next
            }
            for command in replaceFrame(change) { send(command) }
        }
        return permits()
    }

    public mutating func releaseAll() -> [SensorCommand] {
        let before = active
        owners.removeAll()
        return before.sorted().map { .init(.init(.sustain,channel:$0),value:0) }
    }
}

/// Shared legacy Touch pedal targets. Before note edges only already
/// allocated channels are eligible; after allocation the normal idle
/// fallback remains available. Existing sustained voices retain ownership.
public enum LegacyTouchSustainTargets {
    /// Standard destinations are known even before a note exists. MPE
    /// members are dynamic: never send CC64 to a guessed idle member
    /// or the zone master. GM drums remain on their fixed channel.
    public static func fixedChannels(baseChannel:Int,hasMelody:Bool,hasDrums:Bool,isMPE:Bool) -> Set<Int> {
        var channels: Set<Int> = []
        if hasDrums { channels.insert(GMDrumPads.midiChannel) }
        if hasMelody && !isMPE {
            channels.insert(SurfaceMIDIChannel.melodic(base:baseChannel,hasMIDIDrums:hasDrums))
        }
        return channels
    }

    public static func routed(active:Bool,previous:Set<Int>,current:Set<Int>,fixed:Set<Int>) -> Set<Int> {
        guard active else { return [] }
        return previous.union(current).union(fixed).filter { (0...15).contains($0) }
    }

    public static func resolve(active:Bool,previous:Set<Int>,current:Set<Int>,
                               baseChannel:Int,allowIdleFallback:Bool) -> Set<Int> {
        guard active else { return [] }
        let targets = previous.union(current).filter { (0...15).contains($0) }
        if targets.isEmpty && allowIdleFallback { return [max(0,min(15,baseChannel))] }
        return targets
    }
}
