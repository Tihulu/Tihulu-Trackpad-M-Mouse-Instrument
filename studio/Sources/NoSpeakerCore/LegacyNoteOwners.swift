/// One note gate per channel/note on a shared outgoing endpoint.
/// Owner replacement is idempotent; no retrigger while another owner holds.
public struct LegacyNoteOwners<Owner: Hashable> {
    private var owners: [Owner:SensorDestination] = [:]
    public init() {}
    public var active: Set<SensorDestination> { Set(owners.values) }

    public mutating func release(_ owner: Owner) -> [SensorCommand] {
        guard let target = owners.removeValue(forKey:owner),
              !owners.values.contains(target) else { return [] }
        return [.init(target,value:0)]
    }

    public mutating func press(_ owner: Owner, channel: Int, note: Int, velocity: Int) -> [SensorCommand] {
        guard (0...15).contains(channel),(0...127).contains(note),(1...127).contains(velocity) else { return [] }
        let target = SensorDestination(.note,channel:channel,number:note)
        guard owners[owner] != target else { return [] }
        var commands = release(owner)
        let alreadyHeld = owners.values.contains(target)
        owners[owner] = target
        if !alreadyHeld { commands.append(.init(target,value:velocity)) }
        return commands
    }

    public mutating func releaseAll() -> [SensorCommand] {
        let targets = active.sorted { $0.channel == $1.channel ? $0.number < $1.number : $0.channel < $1.channel }
        owners.removeAll()
        return targets.map { .init($0,value:0) }
    }
}
