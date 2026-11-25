#if os(macOS)
import SwiftUI
import NoSpeakerCore

/// Host-side draft editor, not a live or remote browser configuration API.
struct PerformanceGroupMobileDraftView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var draft:PerformanceGroupMobileDraft
    @State private var signal:SensorSignal = .contact
    @State private var widgetSignal:SensorSignal = .contact
    @State private var message = ""
    let apply:(PerformanceGroupMobileDraft)->Bool

    init(draft:PerformanceGroupMobileDraft,apply:@escaping(PerformanceGroupMobileDraft)->Bool) {
        _draft = State(initialValue:draft)
        self.apply = apply
    }

    private var validation:PerformanceGroupProfile? {
        try? draft.applying(to:draft.baseline)
    }

    var body:some View {
        VStack(alignment:.leading,spacing:12) {
            Text("Mobile mapping · " + draft.source.rawValue).font(.headline)
            Text("Configure host MIDI targets for this group's slot. Browser controls remain fixed XY, drum, piano and pedal surfaces. Layout labels and order below are host-only metadata.")
                .font(.caption).foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment:.leading,spacing:8) {
                    HStack {
                        Picker("Add control",selection:$signal) {
                            ForEach(PerformanceGroupMobileDraft.signals,id:\.self) { item in Text(item.rawValue).tag(item) }
                        }
                        Button("Add") {
                            if !draft.append(signal) { message = "Already mapped or no room." }
                        }.disabled(!draft.availableSignals.contains(signal))
                    }
                    Text("Remaining MIDI targets across all groups: \(draft.remainingRouteCapacity)")
                        .font(.caption).foregroundStyle(.secondary)
                    ForEach($draft.routes) { $route in
                        GroupBox {
                            VStack(alignment:.leading,spacing:5) {
                                Text(route.signal.rawValue).font(.headline)
                                Picker("MIDI target",selection:$route.destination.kind) {
                                    ForEach(SensorDestinationKind.allCases,id:\.self) { kind in Text(kind.rawValue).tag(kind) }
                                }
                                Stepper("Channel \(route.destination.channel+1)",value:$route.destination.channel,in:0...15)
                                if route.destination.kind == .note || route.destination.kind == .controlChange {
                                    Stepper("Number \(route.destination.number)",value:$route.destination.number,in:0...(route.destination.kind == .note ? 127 : 119))
                                } else {
                                    Button("Set unused number to zero") { route.destination.number = 0 }
                                        .disabled(route.destination.number == 0)
                                }
                                if route.destination.kind == .note {
                                    Stepper("Velocity \(route.velocity)",value:$route.velocity,in:1...127)
                                }
                                Stepper("Priority \(route.priority)",value:$route.priority,in:-100...100)
                                if ContinuousResponse.isContinuous(route.destination) {
                                    Text("Release: " + String(route.response?.releaseValue(for:route.destination) ?? ContinuousResponse.defaultRelease(route.destination)))
                                        .font(.caption)
                                    HStack {
                                        Button("Explicit zero release") {
                                            var response = route.response ?? .init()
                                            response.release = 0
                                            route.response = response
                                        }
                                        Button("Explicit center release") {
                                            var response = route.response ?? .init()
                                            response.release = 0.5
                                            route.response = response
                                        }
                                    }
                                }
                                if route.response != nil {
                                    Button("Remove custom response") { route.response = nil }
                                }
                                Button("Duplicate MIDI target for this input") {
                                    if !draft.duplicateMapping(route.id) {
                                        message = "No capacity or invalid target. Correct the mapping before duplicating."
                                    } else {
                                        message = "Target copied. Change the new row's MIDI destination as needed."
                                    }
                                }.disabled(draft.remainingRouteCapacity == 0)
                                Button("Remove mapping",role:.destructive) {
                                    let id = route.id
                                    draft.routes.removeAll { $0.id == id }
                                }
                            }
                        }
                    }
                    Divider()
                    Text("Host layout metadata").font(.headline)
                    HStack {
                        Picker("Control label",selection:$widgetSignal) {
                            ForEach(PerformanceGroupMobileDraft.signals,id:\.self) { item in Text(item.rawValue).tag(item) }
                        }
                        Button("Add layout item") {
                            if !draft.addWidget(widgetSignal) { message = "Map this input first, or edit its existing item." }
                        }
                    }
                    ForEach($draft.widgets) { $widget in
                        VStack(alignment:.leading,spacing:4) {
                            Text(widget.signal.rawValue).font(.caption)
                            TextField("Host label",text:$widget.label)
                            Picker("Host widget style",selection:$widget.kind) {
                                ForEach(PerformanceControlKind.allCases) { kind in Text(kind.rawValue).tag(kind) }
                            }
                            Toggle("Wide host widget",isOn:$widget.wide)
                            HStack {
                                Button("Move up") {
                                    let id = widget.id
                                    if let i = draft.widgets.firstIndex(where:{ $0.id == id }),i > 0 {
                                        draft.widgets.swapAt(i,i-1)
                                    }
                                }.disabled(draft.widgets.first?.id == widget.id)
                                Button("Remove layout item",role:.destructive) {
                                    let id = widget.id
                                    draft.widgets.removeAll { $0.id == id }
                                }
                            }
                        }.padding(5)
                    }
                }
            }
            Text(validation == nil ? "Invalid target, layout, capacity or more than two surface families across this slot. CC7/11 require explicit release; reserved CCs are refused." : "Draft is valid. Apply, then save the group profile. No MIDI is sent.")
                .font(.caption).foregroundStyle(validation == nil ? Color.orange : Color.secondary)
            if !message.isEmpty { Text(message).font(.caption) }
            HStack {
                Button("Cancel") { dismiss() }
                Spacer()
                Button("Apply to group draft") {
                    if apply(draft) { dismiss() }
                    else { message = "Profile changed or editing is locked. Nothing applied." }
                }.disabled(validation == nil)
            }
        }.padding(16).frame(minWidth:470,minHeight:530)
    }
}
#endif
