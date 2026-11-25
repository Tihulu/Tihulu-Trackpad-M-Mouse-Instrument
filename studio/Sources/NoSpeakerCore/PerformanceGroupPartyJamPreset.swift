import Foundation

/// Offline, opt-in starting layouts for independent MIDI group ports.
/// No listener, device binding, tuning, or MIDI output is started.
public enum PerformanceGroupPartyJamPreset:String,CaseIterable,Identifiable,Sendable {
    case mobileQuartet, hybridBand
    public var id:String { rawValue }
    public var title:String {
        switch self {
        case .mobileQuartet: return "Four mobile controllers"
        case .hybridBand: return "Four mobile + two Xbox + Trackpad / Mouse"
        }
    }
    public var detail:String {
        switch self {
        case .mobileQuartet: return "Phone drums; tablet keys; phone2 XY lead; tablet2 pedals across keys and lead."
        case .hybridBand: return "Mobile quartet plus Xbox lead/helper and a separate Trackpad bass with Magic Mouse sustain."
        }
    }

    public func makeProfile() -> PerformanceGroupProfile? {
        let drums = PerformanceInstrumentGroup(name:"Drums · phone",patch:.init(
            name:"Phone drums",routes:RemoteDrumPads.routes(source:.phone)))
        var keyRoutes = RemotePiano.routes(source:.tablet)
        keyRoutes.append(.init(id:"external-sustain",source:.tablet2,signal:.pedalSustain,destination:.init(.sustain)))
        let keys = PerformanceInstrumentGroup(name:"Keys · tablet",patch:.init(name:"Keys and pedal",routes:keyRoutes))
        let lead = PerformanceInstrumentGroup(name:"Lead · phone2",patch:.init(name:"XY lead and pedal",routes:[
            .init(id:"lead-contact",source:.phone2,signal:.contact,destination:.init(.note,number:60)),
            .init(id:"lead-bend",source:.phone2,signal:.x,destination:.init(.pitchBend)),
            .init(id:"lead-filter",source:.phone2,signal:.y,destination:.init(.controlChange,number:74)),
            .init(id:"lead-mod",source:.tablet2,signal:.pedalExpression,destination:.init(.controlChange,number:1)),
            .init(id:"lead-resonance",source:.tablet2,signal:.pedalWah,destination:.init(.controlChange,number:71)),
            .init(id:"lead-switch",source:.tablet2,signal:.pedalSwitch1,destination:.init(.controlChange,number:80))
        ]))
        var groups = [drums,keys,lead]
        if self == .hybridBand {
            let guitar = GamepadFrame.Role.lead.routes(source:.gamepad1,channel:0) +
                GamepadFrame.Role.helper.routes(source:.gamepad2,channel:0)
            groups.append(.init(name:"Xbox lead and helper",patch:.init(name:"Xbox duo",routes:guitar)))
            groups.append(.init(name:"Bass · Trackpad / Mouse",patch:.init(name:"Bass and sustain",routes:[
                .init(id:"bass-note",source:.trackpad,signal:.contact,destination:.init(.note,number:36)),
                .init(id:"bass-bend",source:.trackpad,signal:.x,destination:.init(.pitchBend)),
                .init(id:"bass-pedal",source:.magicMouse,signal:.contact,destination:.init(.sustain))
            ])))
        }
        let profile = PerformanceGroupProfile(groups:groups)
        guard profile.isValid,profile.layeredInputs.isEmpty,
              PerformanceGroupGamepadSession.supports(profile,allowSurfaces:true,allowRemote:true),
              (try? PerformanceGroupEndpointPlan(profile:profile)) != nil else { return nil }
        return profile
    }

    /// Only populate a genuinely empty draft. No replacement, merge, or
    /// implicit activation of a saved workspace.
    @discardableResult
    public func install(in draft:inout PerformanceGroupProfile) -> Bool {
        guard draft.groups.isEmpty,let next = makeProfile() else { return false }
        draft = next
        return true
    }
}
