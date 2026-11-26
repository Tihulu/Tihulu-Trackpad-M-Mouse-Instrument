import Foundation

/// Offline haptic projection consuming reconciled wire MIDI, never raw
/// input events. No timer, driver or MIDI endpoint. Tuned groups require
/// an explicit frozen plan and successful setup before observation.
public struct PerformanceGroupHapticProjection: Sendable {
    public enum AdmissionError:Error,Equatable { case invalidSelection }
    private var targets:[UUID:Set<SensorDestination>]
    private var voices:[UUID:GamepadHapticVoices]
    private let safety = HapticSafetyPolicy()
    private var pendingAttacks:[GroupHapticAttack] = []
    private var attackEpoch:UInt64 = 0
    public var activeGroups:Set<UUID> { Set(voices.keys) }

    public init(profile:PerformanceGroupProfile,selected:Set<UUID>,tuned:Set<UUID> = []) throws {
        let groups = profile.groups.filter { !$0.patch.routes.isEmpty }
        guard profile.isValid,!selected.isEmpty,selected.isSubset(of:groups.map(\.id)),
              tuned.isSubset(of:groups.map(\.id)),selected.isDisjoint(with:tuned) else {
            throw AdmissionError.invalidSelection
        }
        targets = Dictionary(uniqueKeysWithValues:groups.filter { selected.contains($0.id) }.map {
            ($0.id,Set($0.patch.routes.map(\.destination)))
        })
        voices = Dictionary(uniqueKeysWithValues:selected.map { ($0,GamepadHapticVoices()) })
    }

    /// Explicit prepared-plan path. The caller must construct this only
    /// for the exact plan whose setup completed successfully. Do not pass
    /// setup commands to observe; it accepts only translated live targets.
    public init(profile:PerformanceGroupProfile,selected:Set<UUID>,
                preparedTuning tuning:[UUID:PerformanceGroupTuningPlan.Specification]) throws {
        guard !tuning.isEmpty else { throw AdmissionError.invalidSelection }
        let plan = try PerformanceGroupTuningPlan(profile:profile,tuning:tuning)
        let groups = profile.groups.filter { !$0.patch.routes.isEmpty }
        guard !selected.isEmpty,selected.isSubset(of:groups.map(\.id)) else { throw AdmissionError.invalidSelection }
        var mapped:[UUID:Set<SensorDestination>] = [:]
        var renderers:[UUID:GamepadHapticVoices] = [:]
        for group in groups where selected.contains(group.id) {
            var wire:Set<SensorDestination> = []
            for route in group.patch.routes {
                let item = PerformanceGroupCommand(groupID:group.id,command:.init(route.destination,value:0))
                guard let translated = plan.translate(item) else { throw AdmissionError.invalidSelection }
                wire.insert(translated.command.destination)
            }
            mapped[group.id] = wire
            if let zone = plan.zones[group.id] { renderers[group.id] = .init(zone:zone) }
            else { renderers[group.id] = .init() }
        }
        targets = mapped
        voices = renderers
    }

    /// Dynamic pools retain fixed bends but may reuse a member for another
    /// logical note. Observe only accepted wire commands after successful
    /// preparation. The preview is an immutable plan, not proof of setup.
    public init(preparedDynamic preview:DynamicMPEPreview,selected:Set<UUID>) throws {
        guard !selected.isEmpty,selected.isSubset(of:preview.groups.map(\.id)) else {
            throw AdmissionError.invalidSelection
        }
        var mapped:[UUID:Set<SensorDestination>] = [:]
        var renderers:[UUID:GamepadHapticVoices] = [:]
        for group in preview.groups where selected.contains(group.id) {
            var wire:Set<SensorDestination> = []
            for route in group.routes {
                for channel in route.possibleChannels {
                    var target = route.logical
                    target.channel = channel-1
                    wire.insert(target)
                }
            }
            mapped[group.id] = wire
            renderers[group.id] = .init(members:group.plan.members)
        }
        targets = mapped
        voices = renderers
    }

    /// A failed send invalidates only the selected group's projection.
    /// Successful cleanup cannot revive that group. A native host must also
    /// call retire on explicit group Stop and clear on global Stop/Panic.
    public mutating func observe(_ item:PerformanceGroupCommand,accepted:Bool,now:Double? = nil) {
        guard voices[item.groupID] != nil else { return }
        let command = item.command
        let d = command.destination
        guard accepted,targets[item.groupID]?.contains(d) == true,
              (0...(d.kind == .pitchBend ? 16383 : 127)).contains(command.value),
              d.kind != .sustain || command.value == 0 || command.value == 127 else {
            retire(item.groupID)
            return
        }
        voices[item.groupID]?.apply(command)
        if d.kind == .pitchBend || (d.kind == .sustain && command.value == 0) ||
            (d.kind == .controlChange && [7,11].contains(d.number)) {
            discardAttacks()
        }
        if d.kind == .note,command.value > 0,let now,now.isFinite,now >= 0,
           let frame = voices[item.groupID]?.attackFrame(command) {
            pendingAttacks.removeAll { !$0.isFresh(now:now) }
            if pendingAttacks.count >= HapticAttackBuffer<HapticFrame>.capacity { pendingAttacks.removeFirst() }
            pendingAttacks.append(.init(frame:frame,time:now))
        }
    }

    /// A receipt fence can retire an endpoint even when every attempted
    /// MIDI send and cleanup succeeds. The wire observer alone cannot see
    /// that logical retirement. Consume authoritative delivery reports
    /// before publishing the next held frame or transient snapshot.
    public mutating func reconcileDeliveryReports(_ reports:[PerformanceGroupDelivery.Report]) {
        let failed = reports.reduce(into:Set<UUID>()) { $0.formUnion($1.failedGroups) }
        for id in failed.sorted(by:{ $0.uuidString < $1.uuidString }) { retire(id) }
    }

    /// Conservative: invalidate all unrendered transients across a fault or
    /// changed expression. Held voices on unrelated ports remain intact.
    public mutating func discardAttacks() {
        pendingAttacks.removeAll(keepingCapacity:true)
        attackEpoch &+= 1
    }

    public mutating func snapshot(now:Double) -> GroupHapticSnapshot {
        let attacks = pendingAttacks.filter { $0.isFresh(now:now) }
        pendingAttacks.removeAll(keepingCapacity:true)
        return .init(held:frame(),attacks:attacks,epoch:attackEpoch)
    }

    public mutating func retire(_ group:UUID) {
        if voices.removeValue(forKey:group) != nil { discardAttacks() }
        targets.removeValue(forKey:group)
    }

    public mutating func stop() {
        discardAttacks()
        voices.removeAll()
        targets.removeAll()
    }

    /// Deterministic fair selection across ports, exact-frequency dedup,
    /// bounded total level and at most six tones. Independent groups retain
    /// their own channel/sustain/volume state even if MIDI numbers coincide.
    public func frame() -> HapticFrame? {
        let contributions = voices.keys.sorted { $0.uuidString < $1.uuidString }.compactMap { id -> HapticFrame? in
            voices[id]?.frame()
        }
        guard !contributions.isEmpty else { return nil }
        if contributions.count == 1 { return contributions.first }
        var weighted:[[HapticTone]] = []
        for frame in contributions {
            let sum:Double = frame.tones.reduce(0.0) { $0+$1.amplitude }
            guard sum > 0,sum.isFinite else { continue }
            var source:[HapticTone] = []
            for tone in frame.tones where tone.amplitude > 0 {
                let weight:Double = frame.level*tone.amplitude/sum
                source.append(.init(frequencyHz:tone.frequencyHz,amplitude:weight))
            }
            source.sort { a,b in
                if a.amplitude == b.amplitude { return a.frequencyHz < b.frequencyHz }
                return a.amplitude > b.amplitude
            }
            weighted.append(source)
        }
        var order:[Double] = []
        var levels:[Double:Double] = [:]
        for i in 0..<safety.maxTonesPerFrame {
            for source in weighted where source.count > i {
                let tone = source[i]
                if let old = levels[tone.frequencyHz] { levels[tone.frequencyHz] = max(old,tone.amplitude) }
                else if order.count < safety.maxTonesPerFrame {
                    order.append(tone.frequencyHz)
                    levels[tone.frequencyHz] = tone.amplitude
                }
            }
        }
        let sum = order.reduce(0.0) { $0+(levels[$1] ?? 0) }
        guard sum > 0,sum.isFinite else { return nil }
        return safety.clamp(.init(tones:order.map { .init(frequencyHz:$0,amplitude:(levels[$0] ?? 0)/sum) },
            durationMS:18,level:min(safety.maxLevel,sum)))
    }
}
