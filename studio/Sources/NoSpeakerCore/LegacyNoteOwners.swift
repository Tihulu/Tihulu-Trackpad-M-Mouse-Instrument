/// One note gate per channel/note on a shared outgoing endpoint.
/// Owner replacement is idempotent; no retrigger while another owner holds.
/// The reverse count avoids scanning all held notes on every attack or lift.
public struct LegacyNoteOwners<Owner: Hashable> {
    private var owners: [Owner:SensorDestination] = [:]
    private var counts: [SensorDestination:Int] = [:]
    public init() {}
    public var active: Set<SensorDestination> { Set(counts.keys) }

    public mutating func release(_ owner: Owner) -> [SensorCommand] {
        guard let target = owners.removeValue(forKey:owner) else { return [] }
        if let count = counts[target], count > 1 {
            counts[target] = count - 1
            return []
        }
        counts.removeValue(forKey:target)
        return [.init(target,value:0)]
    }

    public mutating func press(_ owner: Owner, channel: Int, note: Int, velocity: Int) -> [SensorCommand] {
        guard (0...15).contains(channel),(0...127).contains(note),(1...127).contains(velocity) else { return [] }
        let target = SensorDestination(.note,channel:channel,number:note)
        guard owners[owner] != target else { return [] }
        var commands = release(owner)
        let count = counts[target] ?? 0
        owners[owner] = target
        counts[target] = count + 1
        if count == 0 { commands.append(.init(target,value:velocity)) }
        return commands
    }

    /// Release an old gate even if its replacement is too late. Check the
    /// receipt again after the synchronous release before acquiring ownership
    /// of a new gate (including a silent join of an already held note).
    /// False means no new ownership was admitted, not a transport error.
    public mutating func pressAdmitted(_ owner:Owner,channel:Int,note:Int,velocity:Int,
                                       permits:()->Bool,send:(SensorCommand)->Void)->Bool {
        guard (0...15).contains(channel),(0...127).contains(note),(1...127).contains(velocity) else { return false }
        let target=SensorDestination(.note,channel:channel,number:note)
        if owners[owner] == target { return permits() }
        for command in release(owner) { send(command) }
        guard permits() else { return false }
        for command in press(owner,channel:channel,note:note,velocity:velocity) { send(command) }
        return true
    }

    public mutating func releaseAll() -> [SensorCommand] {
        let targets = active.sorted { $0.channel == $1.channel ? $0.number < $1.number : $0.channel < $1.channel }
        owners.removeAll()
        counts.removeAll()
        return targets.map { .init($0,value:0) }
    }
}
