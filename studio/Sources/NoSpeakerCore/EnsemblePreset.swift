import Foundation

/// A host-created ensemble patch. Roles are musical routing labels, not
/// new network privileges: remote admission remains source-scoped.
public enum EnsemblePreset: String, CaseIterable, Identifiable, Sendable {
    case chamber, rhythm
    public var id:String { rawValue }
    public var title:String {
        switch self { case .chamber: "Chamber ensemble"; case .rhythm: "Rhythm jam" }
    }
    public var instructions:String {
        switch self {
        case .chamber: "Phone piano ch 1, tablet piano ch 2, camera conductor expression ch 1–2, Trackpad bass ch 3."
        case .rhythm: "Phone drums ch 10, tablet piano ch 2, camera expression/wah ch 2, Trackpad bass ch 3."
        }
    }
    public func patch() -> InstrumentPatch? {
        var routes:[SensorMapping] = []
        func append(_ values:[SensorMapping],channel:Int) {
            routes += values.map { route in
                var copy = route
                copy.destination.channel = channel
                return copy
            }
        }
        switch self {
        case .chamber:
            append(RemotePiano.routes(source:.phone),channel:0)
            append(RemotePiano.routes(source:.tablet),channel:1)
            for channel in [0,1] {
                if let route = AirHandsHelper.route(hand:.left,axis:.y,effect:.expression,channel:channel) {
                    routes.append(route)
                }
            }
        case .rhythm:
            append(RemoteDrumPads.routes(source:.phone),channel:9)
            append(RemotePiano.routes(source:.tablet),channel:1)
            if let expression = AirHandsHelper.route(hand:.left,axis:.y,effect:.expression,channel:1),
               let wah = AirHandsHelper.route(hand:.right,axis:.aperture,effect:.wah,channel:1) {
                routes += [expression,wah]
            }
        }
        routes += [
            .init(id:"ensemble-bass",source:.trackpad,signal:.contact,destination:.init(.note,channel:2,number:36)),
            .init(id:"ensemble-bass-bend",source:.trackpad,signal:.x,destination:.init(.pitchBend,channel:2)),
            .init(id:"ensemble-bass-expression",source:.trackpad,signal:.y,destination:.init(.controlChange,channel:2,number:11))
        ]
        let result = InstrumentPatch(name:title,routes:routes)
        return PhysicalPatchRuntime.supports(result,allowRemote:true) ? result : nil
    }
}
