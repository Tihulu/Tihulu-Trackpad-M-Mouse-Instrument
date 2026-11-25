import Foundation

/// Offline, source-scoped mapping transaction. The full baseline fences
/// stale editors, including changes to mappings in other groups.
public struct PerformanceGroupMobileDraft: Identifiable, Equatable, Sendable {
    public enum EditError: Error, Equatable {
        case staleProfile, invalidScope, invalidMapping, capacityOrConflict, unsupportedSurface
    }
    public let id = UUID()
    public let groupID: UUID
    public let source: SensorSource
    public let baseline: PerformanceGroupProfile
    public var routes:[SensorMapping]
    public var widgets:[PerformanceWidget]

    public init(profile:PerformanceGroupProfile,groupID:UUID,source:SensorSource) throws {
        guard profile.isValid,source.isGroupRemote,
              let group = profile.groups.first(where:{ $0.id == groupID }) else { throw EditError.invalidScope }
        self.baseline = profile
        self.groupID = groupID
        self.source = source
        routes = group.patch.routes.filter { $0.source == source }
        widgets = group.patch.performanceLayout?.widgets.filter { $0.source == source } ?? []
    }

    public static var signals:[SensorSignal] {
        [.x,.y,.contact] + RemoteDrumPads.signals + RemotePiano.signals + RemotePedalboard.signals
    }
    public var availableSignals:[SensorSignal] {
        Self.signals.filter { signal in !routes.contains(where:{ $0.signal == signal }) }
    }

    /// Defaults are examples, not automatic changes to a DAW. No reserved
    /// selectors, and gain controls explicitly return to zero if chosen.
    public static func suggestedRoute(source:SensorSource,signal:SensorSignal,id:String = UUID().uuidString) -> SensorMapping? {
        guard source.isGroupRemote,signals.contains(signal) else { return nil }
        let target:SensorDestination
        switch signal {
        case .x: target = .init(.pitchBend)
        case .y: target = .init(.controlChange,number:74)
        case .contact: target = .init(.note,number:60)
        case .pianoSustain,.pedalSustain: target = .init(.sustain)
        case .pedalExpression: target = .init(.controlChange,number:1)
        case .pedalVolume: target = .init(.controlChange,number:7)
        case .pedalWah: target = .init(.controlChange,number:74)
        case .pedalSwitch1: target = .init(.controlChange,number:80)
        case .pedalSwitch2: target = .init(.controlChange,number:81)
        default:
            if let i = RemoteDrumPads.signals.firstIndex(of:signal) {
                target = .init(.note,channel:9,number:RemoteDrumPads.defaults[i].note)
            } else if let i = RemotePiano.keySignals.firstIndex(of:signal) {
                target = .init(.note,number:48+i)
            } else { return nil }
        }
        let response:ContinuousResponse? = target.kind == .controlChange && [7,11].contains(target.number) ? .init(release:0) : nil
        return .init(id:id,source:source,signal:signal,destination:target,response:response)
    }

    public mutating func append(_ signal:SensorSignal) -> Bool {
        guard availableSignals.contains(signal),routes.count < PerformanceGroupProfile.maximumRoutes,
              let route = Self.suggestedRoute(source:source,signal:signal) else { return false }
        routes.append(route)
        return true
    }

    /// Layout metadata is host-side only; it never grants new MIDI mappings
    /// or changes the fixed browser wire schema.
    public mutating func addWidget(_ signal:SensorSignal) -> Bool {
        guard routes.contains(where:{ $0.signal == signal }),
              !widgets.contains(where:{ $0.inputs.contains(.init(source:source,signal:signal)) }) else { return false }
        widgets.append(.init(source:source,signal:signal))
        return true
    }

    public func applying(to current:PerformanceGroupProfile) throws -> PerformanceGroupProfile {
        guard current == baseline else { throw EditError.staleProfile }
        guard let i = current.groups.firstIndex(where:{ $0.id == groupID }),
              source.isGroupRemote else { throw EditError.invalidScope }
        guard routes.allSatisfy({ $0.source == source && Self.signals.contains($0.signal) &&
            InstrumentPatch.permits($0) && PerformanceGroupGamepadSession.permitsLiveControl($0) }),
            widgets.allSatisfy({ $0.source == source && Self.signals.contains($0.signal) && $0.isValid })
        else { throw EditError.invalidMapping }
        var next = current
        // Preserve all unrelated routes and widgets, and retain the IDs of
        // existing rows. Dormant layout metadata may remain after removal.
        let patch = current.groups[i].patch
        let replacements = Dictionary(grouping:routes,by:{ $0.id })
        guard replacements.values.allSatisfy({ $0.count == 1 }) else { throw EditError.capacityOrConflict }
        var remaining = routes
        var ordered:[SensorMapping] = []
        for old in patch.routes {
            if old.source != source { ordered.append(old); continue }
            if let index = remaining.firstIndex(where:{ $0.id == old.id }) {
                ordered.append(remaining.remove(at:index))
            }
        }
        ordered += remaining
        next.groups[i].patch.routes = ordered
        if patch.performanceLayout != nil || !widgets.isEmpty {
            var pending = widgets
            var layout:[PerformanceWidget] = []
            for old in patch.performanceLayout?.widgets ?? [] {
                if old.source != source { layout.append(old) }
                else if !pending.isEmpty { layout.append(pending.removeFirst()) }
            }
            layout += pending
            next.groups[i].patch.performanceLayout = .init(widgets:layout)
        }
        guard next.isValid else { throw EditError.capacityOrConflict }
        let remote = Dictionary(grouping:next.groups.flatMap { $0.patch.routes }.filter { $0.source.isGroupRemote },by:{ $0.source })
        guard remote.values.allSatisfy({ PerformanceGroupRemoteSurface.modes(for:$0) != nil }) else { throw EditError.unsupportedSurface }
        return next
    }
}
