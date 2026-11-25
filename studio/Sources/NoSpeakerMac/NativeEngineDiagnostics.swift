#if os(macOS)
import Foundation
import CoreMIDI
import CoreGraphics
import ApplicationServices
import GameController

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

    public static func midi(includeNames:Bool = false) -> MIDISnapshot {
        let sources = MIDIGetNumberOfSources()
        let destinations = MIDIGetNumberOfDestinations()
        let cap = 256
        func label(_ endpoint:MIDIEndpointRef) -> String {
            guard endpoint != 0 else { return "(unavailable)" }
            var value:Unmanaged<CFString>?
            let status = MIDIObjectGetStringProperty(endpoint,kMIDIPropertyDisplayName,&value)
            guard status == noErr,let value else { return "(unavailable)" }
            let original = value.takeRetainedValue() as String
            let clean = original.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }
            let bounded = String(String.UnicodeScalarView(clean.prefix(128)))
            return bounded.isEmpty ? "(unnamed)" : bounded
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
