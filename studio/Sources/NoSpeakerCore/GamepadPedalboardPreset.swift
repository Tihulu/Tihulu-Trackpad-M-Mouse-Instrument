import Foundation

/// Example assignable MIDI targets, not DAW-specific plug-in parameters.
public enum GamepadPedalboardPreset {
    public static func routes(source: SensorSource, channel: Int) -> [SensorMapping] {
        guard GamepadFrame.sources.contains(source), (0...15).contains(channel) else { return [] }
        func route(_ signal: SensorSignal, _ kind: SensorDestinationKind, _ number: Int = 0,
                   _ mode: GamepadPedalMode? = nil) -> SensorMapping {
            .init(id:UUID().uuidString,source:source,signal:signal,
                  destination:.init(kind,channel:channel,number:number),pedalMode:mode)
        }
        return [
            route(.padA,.controlChange,80,.toggle),
            route(.padB,.controlChange,81,.toggle),
            route(.padX,.controlChange,82,.toggle),
            route(.padY,.controlChange,83,.toggle),
            route(.padLB,.controlChange,84,.hold),
            route(.padRB,.controlChange,85,.toggle),
            route(.padLT,.controlChange,74),
            route(.padRT,.sustain,0,.hold),
            route(.padLSX,.pitchBend),
            route(.padRSY,.controlChange,11)
        ]
    }

    /// Explicitly replace only one slot. Never stack a full preset over an
    /// existing controller map or silently replace another instrument.
    public static func install(in patch: InstrumentPatch, source: SensorSource,
                               channel: Int, replaceExisting: Bool = false) throws -> InstrumentPatch {
        guard patch.isValid, GamepadFrame.sources.contains(source), (0...15).contains(channel),
              replaceExisting || !patch.routes.contains(where:{ $0.source == source }) else {
            throw SensorRouterError.invalidMappings
        }
        var next = patch
        next.routes.removeAll { $0.source == source }
        next.routes += routes(source:source,channel:channel)
        guard next.isValid else { throw SensorRouterError.invalidMappings }
        return next
    }
}
