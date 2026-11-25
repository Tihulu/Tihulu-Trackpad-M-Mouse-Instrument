#if os(macOS)
import Foundation
import GameController
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
        guard bound.isEmpty else { return false }
        let connected = GCController.controllers()
        var next:[SensorSource:GCController] = [:]
        for source in required.intersection(GamepadFrame.sources) {
            guard let id = source == .gamepad1 ? slot1 : slot2,let controller = available[id],
                  controller.extendedGamepad != nil,connected.contains(where:{ $0 === controller }),
                  !next.values.contains(where:{ $0 === controller }) else { return false }
            next[source] = controller
        }
        bound = next
        return true
    }
    public func read(_ source:SensorSource) -> GamepadFrame? {
        guard let controller = bound[source] else { return nil }
        guard GCController.controllers().contains(where:{ $0 === controller }),let g = controller.extendedGamepad else {
            // Never bind a replacement automatically during a run.
            bound.removeValue(forKey:source)
            return nil
        }
        let buttons:[GCControllerButtonInput?] = [g.buttonA,g.buttonB,g.buttonX,g.buttonY,g.leftShoulder,g.rightShoulder,
            g.dpad.up,g.dpad.down,g.dpad.left,g.dpad.right,g.leftThumbstickButton,g.rightThumbstickButton]
        return GamepadFrame(buttons:buttons.map{ $0?.isPressed == true ? 1 : 0 },
            triggers:[Double(g.leftTrigger.value),Double(g.rightTrigger.value)],
            sticks:[Double(g.leftThumbstick.xAxis.value),Double(g.leftThumbstick.yAxis.value),
                    Double(g.rightThumbstick.xAxis.value),Double(g.rightThumbstick.yAxis.value)])
    }
    public func stop() { bound.removeAll() }
}
#endif
