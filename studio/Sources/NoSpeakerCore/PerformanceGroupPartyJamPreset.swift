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


/// Ready-to-play configurations are templates, not persisted identities.
/// Every copy receives fresh group ports; runtime consent stays explicit.
public enum PerformanceGroupStarterPreset:String,CaseIterable,Identifiable,Sendable {
    case trackpadSolo,mouseSolo,desktopDuo,xboxSolo,xboxDuo,phoneSolo,pocketJam,mobileDuo,cameraLead,touchBarLead,lidLead,mobileQuartet,hybridBand
    case xboxDrums,tabletKeys,mousePedal,xboxHelper,phonePedals
    case phoneXYKeys,tabletKeysDrums,phoneXYEffects,phoneAllSurfaces,tabletAllSurfaces
    public var id:String { rawValue }
    public var title:String {
        switch self {
        case .phoneAllSurfaces: "Phone · four switchable surfaces"
        case .tabletAllSurfaces: "Tablet · four switchable surfaces"
        case .phoneXYKeys: "Phone · XY + piano"
        case .tabletKeysDrums: "Tablet · piano + drums"
        case .phoneXYEffects: "Phone · XY + pedalboard"
        case .xboxDrums: "Xbox drum kit"
        case .tabletKeys: "Tablet keys"
        case .mousePedal: "Trackpad + Mouse pedal"
        case .xboxHelper: "Trackpad + Xbox Helper"
        case .phonePedals: "Trackpad + phone pedals"
        case .trackpadSolo: "Trackpad lead"
        case .mouseSolo: "Magic Mouse lead"
        case .desktopDuo: "Desktop duo"
        case .xboxSolo: "Xbox lead"
        case .xboxDuo: "Xbox band"
        case .phoneSolo: "Phone piano"
        case .pocketJam: "Pocket jam"
        case .mobileDuo: "Mobile duo"
        case .cameraLead: "Camera expression"
        case .touchBarLead: "Touch Bar expression"
        case .lidLead: "Lid expression"
        case .mobileQuartet: "Mobile quartet"
        case .hybridBand: "Full hybrid band"
        }
    }
    public var detail:String {
        switch self {
        case .phoneAllSurfaces,.tabletAllSurfaces: "Switch between XY lead, piano, drum pads and pedalboard on the device. Dedicated drum port; at most two active surfaces."
        case .phoneXYKeys: "Switch on phone between XY lead and piano on the same instrument port."
        case .tabletKeysDrums: "Switch on tablet between piano and drum pads on independent MIDI ports."
        case .phoneXYEffects: "Switch on phone between XY lead and pedalboard with pitch bend, sustain and effects."
        case .xboxDrums: "Eight buttons mapped to GM drums on MIDI channel 10."
        case .tabletKeys: "25 piano keys and sustain on a tablet."
        case .mousePedal: "Trackpad lead; hold Mouse contact for sustain on the same MIDI port."
        case .xboxHelper: "Trackpad lead; Xbox RT sustain, LT filter, left X bend, right Y modulation. Helper axes take priority while active."
        case .phonePedals: "Trackpad lead; phone sustain, wah/filter, modulation and two MIDI switches. No audio effect is created automatically."
        case .trackpadSolo: "Touch = held note; X = pitch bend, Y = filter."
        case .mouseSolo: "Mouse touch = held note; X = bend, Y = filter."
        case .desktopDuo: "Trackpad lead and Magic Mouse bass on independent ports."
        case .xboxSolo: "ABXY notes, sticks for bend/filter, RT sustain."
        case .xboxDuo: "Controller 1 lead; controller 2 drums."
        case .phoneSolo: "Phone piano keys and sustain."
        case .pocketJam: "Trackpad bass and phone drum pads."
        case .mobileDuo: "Phone drums and tablet piano."
        case .cameraLead: "Trackpad lead; one hand controls filter and modulation."
        case .touchBarLead: "Trackpad lead; compatible Touch Bar ribbon controls modulation."
        case .lidLead: "Trackpad lead; compatible lid angle controls filter."
        case .mobileQuartet: PerformanceGroupPartyJamPreset.mobileQuartet.detail
        case .hybridBand: PerformanceGroupPartyJamPreset.hybridBand.detail
        }
    }
    public var requiredSources:[SensorSource] {
        switch self {
        case .phoneXYKeys,.phoneXYEffects,.phoneAllSurfaces: [.phone]
        case .tabletKeysDrums,.tabletAllSurfaces: [.tablet]
        case .xboxDrums: [.gamepad1]
        case .tabletKeys: [.tablet]
        case .mousePedal: [.trackpad,.magicMouse]
        case .xboxHelper: [.trackpad,.gamepad1]
        case .phonePedals: [.trackpad,.phone]
        case .trackpadSolo: [.trackpad]
        case .mouseSolo: [.magicMouse]
        case .desktopDuo: [.trackpad,.magicMouse]
        case .xboxSolo: [.gamepad1]
        case .xboxDuo: [.gamepad1,.gamepad2]
        case .phoneSolo: [.phone]
        case .pocketJam: [.trackpad,.phone]
        case .mobileDuo: [.phone,.tablet]
        case .cameraLead: [.trackpad,.camera]
        case .touchBarLead: [.trackpad,.touchBar]
        case .lidLead: [.trackpad,.lid]
        case .mobileQuartet: [.phone,.tablet,.phone2,.tablet2]
        case .hybridBand: [.phone,.tablet,.phone2,.tablet2,.gamepad1,.gamepad2,.trackpad,.magicMouse]
        }
    }
    public var requiresMobile:Bool { requiredSources.contains(where: { $0.isGroupRemote }) }
    public var isOptionalHardware:Bool { [.cameraLead,.touchBarLead,.lidLead].contains(self) }
    public func makeProfile() -> PerformanceGroupProfile? {
        if self == .mobileQuartet { return PerformanceGroupPartyJamPreset.mobileQuartet.makeProfile() }
        if self == .hybridBand { return PerformanceGroupPartyJamPreset.hybridBand.makeProfile() }
        func group(_ name:String,_ routes:[SensorMapping]) -> PerformanceInstrumentGroup {
            .init(name:name,patch:.init(name:name,routes:routes))
        }
        func surface(_ source:SensorSource,note:Int) -> [SensorMapping] {
            [
                .init(id:"contact",source:source,signal:.contact,destination:.init(.note,number:note)),
                .init(id:"bend",source:source,signal:.x,destination:.init(.pitchBend)),
                .init(id:"filter",source:source,signal:.y,destination:.init(.controlChange,number:74))
            ]
        }
        let lead=surface(.trackpad,note:60)
        let drums=group("Phone drums",RemoteDrumPads.routes(source:.phone))
        let groups:[PerformanceInstrumentGroup]
        switch self {
        case .phoneAllSurfaces,.tabletAllSurfaces:
            let source:SensorSource = self == .phoneAllSurfaces ? .phone : .tablet
            let controls:[SensorMapping] = [
                .init(id:"mobile-bend",source:source,signal:.pedalExpression,destination:.init(.pitchBend),priority:10),
                .init(id:"mobile-filter",source:source,signal:.pedalWah,destination:.init(.controlChange,number:74),priority:10),
                .init(id:"mobile-sustain",source:source,signal:.pedalSustain,destination:.init(.sustain)),
                .init(id:"mobile-switch",source:source,signal:.pedalSwitch1,destination:.init(.controlChange,number:80))
            ]
            groups=[group("Mobile lead and keys",surface(source,note:60)+RemotePiano.routes(source:source)+controls),
                    group("Mobile drums",RemoteDrumPads.routes(source:source))]
        case .phoneXYKeys: groups=[group("Phone XY and keys",surface(.phone,note:60)+RemotePiano.routes(source:.phone))]
        case .tabletKeysDrums: groups=[group("Tablet piano",RemotePiano.routes(source:.tablet)),
                                      group("Tablet drums",RemoteDrumPads.routes(source:.tablet))]
        case .phoneXYEffects: groups=[group("Phone XY and effects",surface(.phone,note:60)+[
            .init(id:"pedal-bend",source:.phone,signal:.pedalExpression,destination:.init(.pitchBend),priority:10),
            .init(id:"pedal-filter",source:.phone,signal:.pedalWah,destination:.init(.controlChange,number:74),priority:10),
            .init(id:"pedal-sustain",source:.phone,signal:.pedalSustain,destination:.init(.sustain)),
            .init(id:"pedal-switch",source:.phone,signal:.pedalSwitch1,destination:.init(.controlChange,number:80))
        ])]
        case .xboxDrums: groups=[group("Xbox drums",GamepadFrame.Role.drums.routes(source:.gamepad1,channel:9))]
        case .tabletKeys: groups=[group("Tablet keys",RemotePiano.routes(source:.tablet))]
        case .mousePedal: groups=[group("Trackpad lead and pedal",lead+[
            .init(id:"mouse-sustain",source:.magicMouse,signal:.contact,destination:.init(.sustain))
        ])]
        case .xboxHelper:
            let helper=GamepadFrame.Role.helper.routes(source:.gamepad1,channel:0).map { route -> SensorMapping in
                var next=route;next.priority=10;return next
            }
            groups=[group("Trackpad lead and Xbox Helper",lead+helper)]
        case .phonePedals: groups=[group("Trackpad lead and phone pedals",lead+[
            .init(id:"phone-sustain",source:.phone,signal:.pedalSustain,destination:.init(.sustain)),
            .init(id:"phone-filter",source:.phone,signal:.pedalWah,destination:.init(.controlChange,number:74),priority:10),
            .init(id:"phone-mod",source:.phone,signal:.pedalExpression,destination:.init(.controlChange,number:1)),
            .init(id:"phone-switch1",source:.phone,signal:.pedalSwitch1,destination:.init(.controlChange,number:80)),
            .init(id:"phone-switch2",source:.phone,signal:.pedalSwitch2,destination:.init(.controlChange,number:81))
        ])]
        case .trackpadSolo: groups=[group("Trackpad lead",lead)]
        case .mouseSolo: groups=[group("Mouse lead",surface(.magicMouse,note:60))]
        case .desktopDuo: groups=[group("Trackpad lead",lead),group("Mouse bass",surface(.magicMouse,note:36))]
        case .xboxSolo: groups=[group("Xbox lead",GamepadFrame.Role.lead.routes(source:.gamepad1,channel:0))]
        case .xboxDuo: groups=[group("Xbox lead",GamepadFrame.Role.lead.routes(source:.gamepad1,channel:0)),
                               group("Xbox drums",GamepadFrame.Role.drums.routes(source:.gamepad2,channel:9))]
        case .phoneSolo: groups=[group("Phone piano",RemotePiano.routes(source:.phone))]
        case .pocketJam: groups=[group("Trackpad bass",surface(.trackpad,note:36)),drums]
        case .mobileDuo: groups=[drums,group("Tablet keys",RemotePiano.routes(source:.tablet))]
        case .cameraLead: groups=[group("Camera lead",lead+[
            .init(id:"camera-filter",source:.camera,signal:.x,destination:.init(.controlChange,number:74),priority:10),
            .init(id:"camera-mod",source:.camera,signal:.y,destination:.init(.controlChange,number:1))
        ])]
        case .touchBarLead: groups=[group("Ribbon lead",lead+[
            .init(id:"ribbon",source:.touchBar,signal:.x,destination:.init(.controlChange,number:1))
        ])]
        case .lidLead: groups=[group("Lid lead",lead+[
            .init(id:"lid",source:.lid,signal:.angle,destination:.init(.controlChange,number:74),priority:10)
        ])]
        case .mobileQuartet,.hybridBand: return nil
        }
        let profile=PerformanceGroupProfile(groups:groups)
        guard profile.isValid,profile.layeredInputs.isEmpty,
              PerformanceGroupGamepadSession.supports(profile,allowSurfaces:true,allowScalars:true,allowCamera:true,allowRemote:requiresMobile),
              (try? PerformanceGroupEndpointPlan(profile:profile)) != nil else { return nil }
        return profile
    }

    /// Append only if the combination is valid and introduces no new
    /// shared input layering. Existing draft identities are preserved.
    public func appending(to draft:PerformanceGroupProfile) -> PerformanceGroupProfile? {
        guard draft.isValid,let template=makeProfile() else { return nil }
        let next=PerformanceGroupProfile(groups:draft.groups+template.groups)
        let previousInputs=Set(draft.groups.flatMap { $0.patch.routes.map { PatchSimulation.Input(source:$0.source,signal:$0.signal) } })
        let newInputs=Set(template.groups.flatMap { $0.patch.routes.map { PatchSimulation.Input(source:$0.source,signal:$0.signal) } })
        guard previousInputs.isDisjoint(with:newInputs),next.isValid,
              PerformanceGroupGamepadSession.supports(next,allowSurfaces:true,allowScalars:true,allowCamera:true,allowRemote:true),
              (try? PerformanceGroupEndpointPlan(profile:next)) != nil else { return nil }
        return next
    }
}
