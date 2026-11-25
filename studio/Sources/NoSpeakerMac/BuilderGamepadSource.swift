#if os(macOS)
import Foundation
@preconcurrency import GameController
import NoSpeakerCore

/// Main-actor adapter to paired macOS controllers. Session bindings are
/// frozen by object identity, not display name, OS player index or order.
@MainActor public final class BuilderGamepadSource {
    public struct Choice:Identifiable,Equatable {
        public let id:UUID
        public let name:String
    }
    private var available:[UUID:GCController] = [:]
    private var bound:[SensorSource:GCController] = [:]
    private var eventToken: UUID?
    private var previousQueues: [SensorSource:DispatchQueue] = [:]
    public init() {}
    public func refresh() -> [Choice] {
        var next:[UUID:GCController] = [:]
        var result:[Choice] = []
        for (index,controller) in GCController.controllers().filter({ $0.extendedGamepad != nil }).prefix(16).enumerated() {
            let id = available.first(where:{ $0.value === controller })?.key ?? UUID()
            next[id] = controller
            result.append(.init(id:id,name:"\(index+1) · "+(controller.vendorName ?? "Game controller")))
        }
        available = next
        return result
    }
    public func bind(required:Set<SensorSource>,slot1:UUID?,slot2:UUID?) -> Bool {
        var choices: [SensorSource:UUID] = [:]
        choices[.gamepad1] = slot1
        choices[.gamepad2] = slot2
        return bind(required:required,choices:choices)
    }

    public func bind(required:Set<SensorSource>,choices:[SensorSource:UUID]) -> Bool {
        guard bound.isEmpty else { return false }
        let connected = GCController.controllers()
        var next:[SensorSource:GCController] = [:]
        for source in required.intersection(GamepadFrame.sources) {
            guard let id = choices[source],let controller = available[id],
                  controller.extendedGamepad != nil,connected.contains(where:{ $0 === controller }),
                  !next.values.contains(where:{ $0 === controller }) else { return false }
            next[source] = controller
        }
        bound = next
        return true
    }
    /// GameController delivers these callbacks on the explicitly selected main
    /// queue. Handle immediately, without creating a separate task per edge.
    /// Polling remains the heartbeat/disconnect fallback.
    public func beginEvents(onFrame: @escaping @MainActor (SensorSource,GamepadFrame?) -> Void) {
        guard eventToken == nil, !bound.isEmpty else { return }
        let token = UUID()
        eventToken = token
        for (source,controller) in bound {
            guard let profile = controller.extendedGamepad else { continue }
            previousQueues[source] = controller.handlerQueue
            controller.handlerQueue = .main
            profile.valueChangedHandler = { [weak self] _,_ in
                MainActor.assumeIsolated {
                    guard let self, self.eventToken == token else { return }
                    onFrame(source,self.read(source))
                }
            }
        }
    }

    public func read(_ source:SensorSource) -> GamepadFrame? {
        guard let controller = bound[source] else { return nil }
        guard GCController.controllers().contains(where:{ $0 === controller }),let g = controller.extendedGamepad else {
            // Never bind a replacement automatically during a run.
            detach(source)
            return nil
        }
        let buttons:[GCControllerButtonInput?] = [g.buttonA,g.buttonB,g.buttonX,g.buttonY,g.leftShoulder,g.rightShoulder,
            g.dpad.up,g.dpad.down,g.dpad.left,g.dpad.right,g.leftThumbstickButton,g.rightThumbstickButton]
        return GamepadFrame(buttons:buttons.map{ $0?.isPressed == true ? 1 : 0 },
            triggers:[Double(g.leftTrigger.value),Double(g.rightTrigger.value)],
            sticks:[Double(g.leftThumbstick.xAxis.value),Double(g.leftThumbstick.yAxis.value),
                    Double(g.rightThumbstick.xAxis.value),Double(g.rightThumbstick.yAxis.value)])
    }
    private func detach(_ source:SensorSource) {
        guard let controller = bound.removeValue(forKey:source) else { return }
        if let queue = previousQueues.removeValue(forKey:source) {
            controller.extendedGamepad?.valueChangedHandler = nil
            controller.handlerQueue = queue
        }
    }

    public func stop() {
        eventToken = nil
        for source in Array(bound.keys) { detach(source) }
        previousQueues.removeAll()
    }
}
#endif
