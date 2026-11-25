#if os(macOS)
import Foundation
import CoreMIDI
import CoreGraphics
import ApplicationServices
import GameController
import NoSpeakerCore

/// Read-only native discovery. No MIDI client, event tap, discovery session
/// or actuator is created. Inventory is not proof of DAW reception.
@MainActor
public enum NativeEngineDiagnostics {
    public struct MIDISnapshot: Encodable, Sendable {
        public let sourceCount:Int
        public let destinationCount:Int
        public let sourceNames:[String]?
        public let destinationNames:[String]?
        public let namesTruncated:Bool
    }

    public struct Preflight: Encodable, Sendable {
        public let accessibilityGranted:Bool
        public let inputMonitoringGranted:Bool
        public let connectedGamepadCount:Int
        public let midi:MIDISnapshot
    }

    public struct GamepadSnapshot: Encodable, Sendable {
        public struct Device: Encodable, Sendable {
            // Snapshot ordinal, never a stable physical ID or live slot.
            public let ordinal:Int
            public let name:String?
            public let extendedProfile:Bool
            public let leftStickClick:Bool
            public let rightStickClick:Bool
        }
        public let connectedCount:Int
        public let extendedProfileCount:Int
        public let maximumLogicalSlots:Int
        public let omittedCount:Int
        public let devices:[Device]
    }

    public struct GamepadSamples: Encodable, Sendable {
        public struct Device: Encodable, Sendable {
            public let ordinal:Int
            public let status:String
            public let active:[String:Double]?
        }
        public let connectedCount:Int
        public let omittedCount:Int
        public let devices:[Device]
    }

    /// One explicit snapshot, no binding, discovery, handlers, or output.
    /// Ordinals identify this inventory only. Never reuse them as slot IDs.
    public static func sampleGamepads() -> GamepadSamples {
        let connected=GCController.controllers()
        let devices=connected.prefix(16).enumerated().map { index,controller -> GamepadSamples.Device in
            guard let profile=controller.extendedGamepad else {
                return .init(ordinal:index+1,status:"unsupported",active:nil)
            }
            guard let frame=BuilderGamepadSource.snapshot(profile) else {
                return .init(ordinal:index+1,status:"invalid",active:nil)
            }
            guard GCController.controllers().contains(where:{ $0 === controller }) else {
                return .init(ordinal:index+1,status:"disconnected",active:nil)
            }
            return .init(ordinal:index+1,status:"sampled",
                active:Dictionary(uniqueKeysWithValues:frame.active.map { ($0.key.rawValue,$0.value) }))
        }
        return .init(connectedCount:connected.count,omittedCount:max(0,connected.count-devices.count),devices:devices)
    }

    private static func safeLabel(_ original:String) -> String {
        let clean = original.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }
        let bounded = String(String.UnicodeScalarView(clean.prefix(128)))
        return bounded.isEmpty ? "(unnamed)" : bounded
    }

    public static func gamepads(includeNames:Bool = false) -> GamepadSnapshot {
        let connected = GCController.controllers()
        let devices = connected.prefix(16).enumerated().map { index,controller in
            let profile = controller.extendedGamepad
            return GamepadSnapshot.Device(ordinal:index+1,
                name:includeNames ? safeLabel(controller.vendorName ?? "Game controller") : nil,
                extendedProfile:profile != nil,
                leftStickClick:profile?.leftThumbstickButton != nil,
                rightStickClick:profile?.rightThumbstickButton != nil)
        }
        return .init(connectedCount:connected.count,
            extendedProfileCount:connected.filter { $0.extendedGamepad != nil }.count,
            maximumLogicalSlots:4,omittedCount:max(0,connected.count-devices.count),devices:devices)
    }

    public static func midi(includeNames:Bool = false) -> MIDISnapshot {
        let sources = MIDIGetNumberOfSources()
        let destinations = MIDIGetNumberOfDestinations()
        let cap = 256
        func label(_ endpoint:MIDIEndpointRef) -> String {
            guard endpoint != 0 else { return "(unavailable)" }
            var value:Unmanaged<CFString>?
            let status = MIDIObjectGetStringProperty(endpoint,kMIDIPropertyDisplayName,&value)
            guard status == noErr,let value else { return "(unavailable)" }
            return safeLabel(value.takeRetainedValue() as String)
        }
        return .init(sourceCount:Int(sources),destinationCount:Int(destinations),
            sourceNames:includeNames ? (0..<min(Int(sources),cap)).map { label(MIDIGetSource($0)) } : nil,
            destinationNames:includeNames ? (0..<min(Int(destinations),cap)).map { label(MIDIGetDestination($0)) } : nil,
            namesTruncated:includeNames && (Int(sources) > cap || Int(destinations) > cap))
    }

    public static func preflight() -> Preflight {
        .init(accessibilityGranted:AXIsProcessTrusted(),
              inputMonitoringGranted:CGPreflightListenEventAccess(),
              connectedGamepadCount:GCController.controllers().count,
              midi:midi())
    }
}
#endif
