import Foundation

/// Joystick axes use the existing continuous router and absolute release
/// policy. No additional sensor stream, timer or MIDI ownership is needed.
public enum GamepadXYMapping {
    public static func replaceAxis(in patch: InstrumentPatch, source: SensorSource,
                                   signal: SensorSignal, target: SensorDestination,
                                   calibration: SensorCalibration = .init(),
                                   response: ContinuousResponse? = nil) throws -> InstrumentPatch {
        guard patch.isValid, GamepadFrame.sources.contains(source),
              GamepadFrame.sticks.contains(signal), ContinuousResponse.isContinuous(target),
              calibration.isValid, response?.isValid ?? true else {
            throw SensorRouterError.invalidMappings
        }
        let previous = patch.routes.filter { $0.source == source && $0.signal == signal }
        let matching = previous.filter { $0.destination == target }
        var route = matching.count == 1 ? matching[0] :
            SensorMapping(id:UUID().uuidString,source:source,signal:signal,destination:target)
        route.calibration = calibration
        route.response = response
        route.pedalMode = nil
        var next = patch
        next.routes.removeAll { $0.source == source && $0.signal == signal }
        next.routes.append(route)
        guard next.isValid else { throw SensorRouterError.invalidMappings }
        return next
    }

    /// Left X: pitch bend. Left Y: positive-half vibrato (zero at center).
    /// Right X: stereo pan. Right Y: filter. Centered CCs release at 64.
    /// Names describe conventional assignments, not guaranteed DAW plugins.
    public static func installExpression(in patch: InstrumentPatch, source: SensorSource,
                                         channel: Int, replaceExisting: Bool = false) throws -> InstrumentPatch {
        guard patch.isValid, GamepadFrame.sources.contains(source), (0...15).contains(channel),
              replaceExisting || !patch.routes.contains(where: {
                  $0.source == source && GamepadFrame.sticks.contains($0.signal)
              }) else { throw SensorRouterError.invalidMappings }
        var next = patch
        next.routes.removeAll { $0.source == source && GamepadFrame.sticks.contains($0.signal) }
        next.routes += [
            .init(id:UUID().uuidString,source:source,signal:.padLSX,
                  destination:.init(.pitchBend,channel:channel)),
            .init(id:UUID().uuidString,source:source,signal:.padLSY,
                  destination:.init(.controlChange,channel:channel,number:1),
                  calibration:.init(minimum:0.5),response:.init(release:0)),
            .init(id:UUID().uuidString,source:source,signal:.padRSX,
                  destination:.init(.controlChange,channel:channel,number:10),
                  response:.init(release:0.5)),
            .init(id:UUID().uuidString,source:source,signal:.padRSY,
                  destination:.init(.controlChange,channel:channel,number:74),
                  response:.init(release:0.5))
        ]
        guard next.isValid else { throw SensorRouterError.invalidMappings }
        return next
    }
}
