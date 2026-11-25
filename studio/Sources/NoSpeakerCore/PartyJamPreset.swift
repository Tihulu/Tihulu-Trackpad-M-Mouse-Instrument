import Foundation

/// Full band using the current bounded router and existing mobile wire protocol.
/// Independent DAW tracks except deliberately shared piano sustain.
public enum PartyJamPreset {
    public static func patch() -> InstrumentPatch? {
        var routes = RemoteDrumPads.routes(source:.phone)
        routes += RemotePiano.routes(source:.tablet).map {
            var r = $0; r.destination.channel = 1; return r
        }
        routes += GamepadFrame.Role.lead.routes(source:.gamepad1,channel:3)
        routes += GamepadFrame.Role.helper.routes(source:.gamepad2,channel:1)
        routes += [
            .init(id:"party-phone-x",source:.phone,signal:.x,destination:.init(.controlChange,channel:9,number:74)),
            .init(id:"party-phone-y",source:.phone,signal:.y,destination:.init(.controlChange,channel:9,number:1)),
            .init(id:"party-bass",source:.trackpad,signal:.contact,destination:.init(.note,channel:2,number:36)),
            .init(id:"party-bass-bend",source:.trackpad,signal:.x,destination:.init(.pitchBend,channel:2)),
            .init(id:"party-mouse-pedal",source:.magicMouse,signal:.contact,destination:.init(.sustain,channel:2)),
            .init(id:"party-lid",source:.lid,signal:.angle,destination:.init(.controlChange,channel:2,number:74)),
            .init(id:"party-ribbon",source:.touchBar,signal:.x,destination:.init(.controlChange,channel:2,number:1))
        ]
        if let effect = AirHandsHelper.route(hand:.left,axis:.y,effect:.modulation,channel:3) { routes.append(effect) }
        let patch = InstrumentPatch(name:"Party Jam · mobile and gamepads",routes:routes)
        return PhysicalPatchRuntime.supports(patch,allowRemote:true) ? patch : nil
    }
}
