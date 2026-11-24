#if os(macOS)
import SwiftUI
import NoSpeakerCore

struct AirHandsHelperPanel: View {
    @Binding var patch: InstrumentPatch
    @Binding var physical: Bool
    @State private var hand = AirHandsHelper.Hand.left
    @State private var axis = AirHandsHelper.Axis.y
    @State private var effect = AirHandsHelper.Effect.expression
    @State private var channel = 0
    @State private var message = ""
    var body: some View {
        GroupBox("Camera MIDI Helper · independent hands") {
            VStack(alignment:.leading,spacing:8) {
                Text("No chord or note mode needed. Use either or both hands for MIDI controls alongside other Builder sources and your DAW.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Picker("Hand",selection:$hand) {
                        ForEach(AirHandsHelper.Hand.allCases) { Text($0.rawValue.capitalized).tag($0) }
                    }
                    Picker("Motion",selection:$axis) {
                        ForEach(AirHandsHelper.Axis.allCases) { Text($0 == .toggle ? "Pinch toggle" : $0 == .pinch ? "Pinch hold" : $0.rawValue.capitalized).tag($0) }
                    }
                    Picker("Effect",selection:$effect) {
                        ForEach(AirHandsHelper.Effect.allCases) { Text($0.title).tag($0) }
                    }
                    Picker("MIDI channel",selection:$channel) {
                        ForEach(0..<16,id:\.self) { Text(String($0+1)).tag($0) }
                    }
                }
                Button("Add helper assignment") {
                    guard let route = AirHandsHelper.route(hand:hand,axis:axis,effect:effect,channel:channel) else {
                        message = "Pedals require Pinch (hold) or Toggle. Toggle is only for pedals."; return
                    }
                    var next = patch
                    next.routes.append(route)
                    guard next.isValid else { message = "Check route capacity, release conflicts or incompatible camera mode."; return }
                    patch = next; physical = true
                    message = "Added. Customize range, inversion, smoothing and MIDI destination in Routes."
                }.disabled(patch.routes.count >= SensorRouter.maxMappings ||
                           patch.routes.contains { $0.source == .camera && !AirHandsHelper.allSignals.contains($0.signal) })
                Text("Pitch bend range is set by the receiving instrument. CC77 vibrato depth, CC76 vibrato rate and CC1 modulation require DAW support. Hold pedals release on opening; toggle pedals change only on a new pinch and always release on tracking loss. No measured force is claimed.")
                    .font(.caption).foregroundStyle(.secondary)
                if !message.isEmpty { Text(message).font(.caption) }
            }.padding(8)
        }
    }
}
#endif
