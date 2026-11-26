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
    @State private var family:PerformanceGroupRemoteSurface = .xy
    @State private var xyzScale = MobileExpressionPreset.major
    @State private var xyzRoot = 60
    @State private var xyzCustom = ""
    @State private var xyzPreset = DepthXYZHelperPreset.expression
    @State private var familyChannel=0
    @State private var familyTranspose=12
    let apply:(PerformanceGroupMobileDraft)->Bool

    init(draft:PerformanceGroupMobileDraft,apply:@escaping(PerformanceGroupMobileDraft)->Bool) {
        _draft = State(initialValue:draft)
        self.apply = apply
    }

    private var validation:PerformanceGroupProfile? {
        return try? draft.applying(to:draft.baseline)
    }

    var body:some View {
        VStack(alignment:.leading,spacing:12) {
            Text("Mobile mapping · " + draft.source.rawValue).font(.headline)
            Text("Configure host MIDI targets for this group's slot. Browser controls remain fixed XY, drum, piano and pedal surfaces. Valid unambiguous custom labels may be displayed on the paired phone; style and order remain host-side metadata.")
                .font(.caption).foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment:.leading,spacing:8) {
                    DisclosureGroup("LiDAR / measured XYZ instrument") {
                        Picker("Key mapping", selection: $xyzScale) {
                            ForEach(MobileExpressionPreset.allCases) { Text($0.title).tag($0) }
                        }
                        if xyzScale == .custom { TextField("MIDI note numbers", text: $xyzCustom) }
                        else { Stepper("Root MIDI note \(xyzRoot)", value: $xyzRoot, in: 0...127) }
                        Stepper("MIDI channel \(familyChannel + 1)", value: $familyChannel, in: 0...15)
                        Button("Add assigned keys to empty mobile slot") {
                            let added = draft.addXYZInstrument(xyzScale, root: xyzRoot, channel: familyChannel, custom: xyzCustom)
                            message = added ? "Keys added. Select Instrument and a pitch axis on the device." : "Check note range, available slots and channel bend ownership."
                        }.disabled(!draft.routes.isEmpty)
                    }
                    DisclosureGroup("LiDAR / measured XYZ helper") {
                        Picker("XYZ preset", selection: $xyzPreset) {
                            ForEach(DepthXYZHelperPreset.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                        }
                        Stepper("MIDI channel \(familyChannel + 1)", value: $familyChannel, in: 0...15)
                        Button("Add XYZ axes to empty mobile slot") {
                            let added = draft.addXYZHelper(xyzPreset, channel: familyChannel)
                            message = added ? "Edit each axis below before applying." : "A target conflicts with another route or the mobile slot is in use."
                        }.disabled(!draft.routes.isEmpty)
                        Text("X uses Pedal 1, Y uses Pedal 2 and Z uses Pedal 3. Choose the same enabled axes on the device. Save the group preset to keep these mappings.").font(.caption)
                    }
                    HStack {
                        Picker("Add control",selection:$signal) {
                            ForEach(PerformanceGroupMobileDraft.signals,id:\.self) { item in Text(item.rawValue).tag(item) }
                        }
                        Button("Add") {
                            if !draft.append(signal) { message = "Already mapped or no room." }
                        }.disabled(!draft.availableSignals.contains(signal))
                    }
                    HStack {
                        Picker("Add surface",selection:$family) {
                            ForEach(PerformanceGroupRemoteSurface.allCases,id:\.self) { item in
                                Text(item.rawValue).tag(item)
                            }
                        }
                        Button("Add missing controls") {
                            message = draft.appendFamily(family)
                                ? "Missing controls added; existing mappings kept."
                                : "No missing controls, insufficient capacity or conflicting surface."
                        }
                    }
                    DisclosureGroup("Selected surface: bulk MIDI routing") {
                        Text("Only existing mappings in this group and mobile slot change. All changes are validated together.")
                            .font(.caption).foregroundStyle(.secondary)
                        Stepper("MIDI channel \(familyChannel+1)",value:$familyChannel,in:0...15)
                        Button("Set channel for selected surface") {
                            message=draft.transformFamily(family,channel:familyChannel)
                                ? "Surface channel updated."
                                : "No change or invalid group configuration. Nothing applied."
                        }
                        Stepper("Transpose notes \(familyTranspose) semitones",value:$familyTranspose,in:-127...127)
                        Button("Transpose selected surface notes") {
                            message=draft.transformFamily(family,transpose:familyTranspose)
                                ? "Surface notes transposed."
                                : "No change, pitch outside MIDI range or conflicting configuration."
                        }.disabled(familyTranspose==0)
                    }
                    Text("Remaining MIDI targets across all groups: \(draft.remainingRouteCapacity)")
                        .font(.caption).foregroundStyle(.secondary)
                    ForEach($draft.routes) { $route in
                        GroupBox {
                            VStack(alignment:.leading,spacing:5) {
                                Text(RemotePedalboard.signals.firstIndex(of: route.signal).flatMap { $0 < 3 ? ["X", "Y", "Z"][$0] + " · " + route.signal.rawValue : nil } ?? route.signal.rawValue).font(.headline)
                                Picker("MIDI target",selection:Binding(
                                    get:{ route.destination.kind },
                                    set:{ kind in
                                        if !draft.retarget(route.id,kind:kind) { message = "Target incompatible with current calibration." }
                                    })) {
                                    ForEach(PerformanceGroupMobileDraft.allowedTargetKinds(for:route.signal),id:\.self) { kind in Text(kind.rawValue).tag(kind) }
                                }
                                Stepper("Channel \(route.destination.channel+1)",value:$route.destination.channel,in:0...15)
                                if route.destination.kind == .note || route.destination.kind == .controlChange {
                                    Picker("MIDI number",selection:Binding(
                                        get:{ route.destination.number },
                                        set:{ number in
                                            if !draft.retarget(route.id,kind:route.destination.kind,number:number) { message = "MIDI target rejected." }
                                        })) {
                                        ForEach(PerformanceGroupMobileDraft.allowedTargetNumbers(for:route.signal,kind:route.destination.kind),id:\.self) { number in
                                            Text(String(number)).tag(number)
                                        }
                                    }
                                }
                                if route.destination.kind == .note {
                                    Stepper("Velocity \(route.velocity)",value:$route.velocity,in:1...127)
                                }
                                Stepper("Priority \(route.priority)",value:$route.priority,in:-100...100)
                                if route.destination.kind == .note || route.destination.kind == .sustain {
                                    Slider(value:$route.threshold,in:0.05...1,step:0.01) { Text("Gate threshold") }
                                    Text("Threshold: " + String(format:"%.2f",route.threshold)).font(.caption)
                                    Slider(value:$route.hysteresis,in:0...0.5,step:0.01) { Text("Gate hysteresis") }
                                    Text("Hysteresis: " + String(format:"%.2f",route.hysteresis)).font(.caption)
                                }
                                if route.signal != .pedalSwitch1 && route.signal != .pedalSwitch2 {
                                    DisclosureGroup("Input calibration") {
                                        Slider(value:$route.calibration.minimum,in:0...1,step:0.01) { Text("Minimum") }
                                        Slider(value:$route.calibration.maximum,in:0...1,step:0.01) { Text("Maximum") }
                                        Text(String(format:"Range %.2f – %.2f",route.calibration.minimum,route.calibration.maximum)).font(.caption)
                                        Slider(value:$route.calibration.deadZone,in:0...0.45,step:0.01) { Text("Dead zone") }
                                        Text(String(format:"Dead zone %.2f",route.calibration.deadZone)).font(.caption)
                                        Slider(value:$route.calibration.exponent,in:0.25...4,step:0.25) { Text("Curve") }
                                        Text(String(format:"Curve %.2f",route.calibration.exponent)).font(.caption)
                                        let sensitivity = Binding<Double>(
                                            get: { route.calibration.sensitivity ?? 1 },
                                            set: { route.calibration.sensitivity = $0 == 1 ? nil : $0 })
                                        Slider(value: sensitivity, in: 0.25...4, step: 0.05) { Text("Sensitivity") }
                                        Text(String(format: "Sensitivity %.2f×", sensitivity.wrappedValue)).font(.caption)
                                        Toggle("Invert",isOn:$route.calibration.inverted)
                                        Button("Reset calibration") { route.calibration = .init() }
                                    }
                                }
                                if ContinuousResponse.isContinuous(route.destination) {
                                    Text("Release: " + String(route.response?.releaseValue(for:route.destination) ?? ContinuousResponse.defaultRelease(route.destination)))
                                        .font(.caption)
                                    if route.signal != .pedalSwitch1 && route.signal != .pedalSwitch2 {
                                        DisclosureGroup("Output range and smoothing") {
                                            let response = Binding<ContinuousResponse>(
                                                get:{ route.response ?? .init() },
                                                set:{ route.response = $0 })
                                            Slider(value:response.minimum,in:0...1,step:0.01) { Text("Output minimum") }
                                            Slider(value:response.maximum,in:0...1,step:0.01) { Text("Output maximum") }
                                            Text(String(format:"Output %.2f – %.2f",response.wrappedValue.minimum,response.wrappedValue.maximum)).font(.caption)
                                            let release = Binding<Double>(
                                                get: { response.wrappedValue.release ?? Double(ContinuousResponse.defaultRelease(route.destination)) / (route.destination.kind == .pitchBend ? 16383 : 127) },
                                                set: { response.wrappedValue.release = $0 })
                                            Slider(value: release, in: 0...1) { Text("Release value") }
                                            Stepper("Smoothing \(response.wrappedValue.smoothingMS) ms",value:response.smoothingMS,in:0...250,step:5)
                                        }
                                    }
                                    HStack {
                                        Button("Explicit zero release") {
                                            var response = route.response ?? .init()
                                            response.release = 0
                                            route.response = response
                                        }.disabled(route.signal == .pedalSwitch1 || route.signal == .pedalSwitch2)
                                        Button("Explicit center release") {
                                            var response = route.response ?? .init()
                                            response.release = 0.5
                                            route.response = response
                                        }.disabled(route.signal == .pedalSwitch1 || route.signal == .pedalSwitch2)
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
                    Text("Control labels and host layout").font(.headline)
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
                            TextField("Custom label (may appear on phone)",text:$widget.label)
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
