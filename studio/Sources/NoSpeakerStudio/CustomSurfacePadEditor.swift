#if os(macOS)
import SwiftUI
import NoSpeakerCore

/// Offline drafts remain separate from a frozen experimental native run.
struct CustomSurfacePadEditor:View {
    @EnvironmentObject private var studio: StudioController
    typealias Layout=CustomSurfacePadLayout
    @State private var expanded=false
    @State private var surface:Layout.Surface = .trackpad
    @State private var layouts:[Layout.Surface:Layout]=[:]
    @AppStorage("TIHULU.customSurfaceLayouts.v1") private var storage=Data()
    @State private var pending:Pending?
    @State private var draftChannels: [Layout.Surface:Int] = [:]
    @State private var preset: CustomSurfacePadPreset = .chromatic
    private func defaultChannel(_ surface: Layout.Surface)->Int { surface == .magicMouse ? 1:0 }
    private func melodicChannel(_ surface: Layout.Surface)->Int { draftChannels[surface] ?? defaultChannel(surface) }
    private func channelBinding(_ surface: Layout.Surface)->Binding<Int> {
        Binding(get:{melodicChannel(surface)},set:{draftChannels[surface]=$0})
    }
    private var groupTrackpadChannel:Int { melodicChannel(.trackpad) }
    private var groupMouseChannel:Int { melodicChannel(.magicMouse) }
    @State private var groupConfirmation:GroupConfirmation?
    @State private var pairConfirmation:PairConfirmation?
    private typealias NativePair = CustomSurfaceLayoutLibrary.NativePair
    private struct PairConfirmation {
        enum Action { case save, load }
        let action: Action
        let trackpad: Layout?
        let mouse: Layout?
        let trackpadChannel: Int
        let mouseChannel: Int
        let storedData: Data
    }
    private var draftPair: NativePair? {
        guard let trackpad=layouts[.trackpad], let mouse=layouts[.magicMouse] else { return nil }
        return .init(trackpad:trackpad,mouse:mouse,trackpadChannel:groupTrackpadChannel,mouseChannel:groupMouseChannel)
    }
    private func requestPair(_ action:PairConfirmation.Action) {
        pending=nil;groupConfirmation=nil
        pairConfirmation = .init(action:action,trackpad:layouts[.trackpad],mouse:layouts[.magicMouse],
            trackpadChannel:groupTrackpadChannel,mouseChannel:groupMouseChannel,storedData:storage)
    }
    private func applyPair(_ operation:PairConfirmation) {
        guard layouts[.trackpad]==operation.trackpad, layouts[.magicMouse]==operation.mouse,
              groupTrackpadChannel==operation.trackpadChannel, groupMouseChannel==operation.mouseChannel,
              storage==operation.storedData, var current=library else {
            feedback="Draft or saved library changed; repeat the pair operation.";return
        }
        switch operation.action {
        case .save:
            guard let pair=draftPair else {feedback="Both drafts are required.";return}
            current.saveNativePair(pair)
            guard let data=try? JSONEncoder().encode(current) else {feedback="Could not encode the pair.";return}
            storage=data;feedback="Both layouts and channels saved."
        case .load:
            guard let pair=current.nativePair else {feedback="No complete saved pair.";return}
            layouts[.trackpad]=pair.trackpad;layouts[.magicMouse]=pair.mouse
            draftChannels[.trackpad]=pair.trackpadChannel;draftChannels[.magicMouse]=pair.mouseChannel
            if surface == .trackpad || surface == .magicMouse {select(layouts[surface]?.pads.first)}
            feedback="Both layouts and channels loaded. Nothing armed."
        }
    }
    private struct GroupConfirmation: Identifiable {
        let id=UUID()
        let trackpad:Layout
        let mouse:Layout
        let trackpadChannel:Int
        let mouseChannel:Int
    }
    private struct Pending:Identifiable {
        enum Action:String {case save,load,reset,arm}
        let action:Action
        let surface:Layout.Surface
        let draft:Layout?
        let saved:Layout?
        let savedChannel:Int?
        let channel:Int
        var id: String {action.rawValue+surface.rawValue}
    }
    private enum Confirmation {
        case single(Pending), group(GroupConfirmation), pair(PairConfirmation)
    }
    private var confirmation: Confirmation? {
        if let pairConfirmation { return .pair(pairConfirmation) }
        if let groupConfirmation { return .group(groupConfirmation) }
        if let pending { return .single(pending) }
        return nil
    }
    private func request(_ action:Pending.Action) {
        groupConfirmation=nil;pairConfirmation=nil
        pending=Pending(action:action,surface:surface,draft:layouts[surface],saved:library?.layout(for:surface),savedChannel:library?.melodicChannel(for:surface),channel:previewChannel)
    }
    private var library:CustomSurfaceLayoutLibrary? {
        storage.isEmpty ? .init() : try? JSONDecoder().decode(CustomSurfaceLayoutLibrary.self,from:storage)
    }
    @State private var selected:String?
    @State private var columns=4
    @State private var rows=2
    @State private var label=""
    @State private var x=0
    @State private var y=0
    @State private var width=2500
    @State private var height=5000
    @State private var note=60
    @State private var kind:Kind = .note
    @State private var changeAssignment=false
    @State private var chordNotes="60, 64, 67"
    @State private var cc=71
    @State private var channel=0
    @State private var xyXCC=1
    @State private var xyYCC=11
    @State private var xyXChannel=0
    @State private var xyYChannel=0
    @State private var xyXBend=false
    @State private var xyYBend=false
    @State private var feedback=""
    @State private var newWidth=1000
    @State private var newHeight=2500
    private var previewChannel:Int { melodicChannel(surface) }
    private enum Kind:String,CaseIterable,Identifiable {
        case note="Note",drum="Drum",degree="Tuning degree",chord="Chord",sustain="Sustain",bend="Pitch bend",cc="Custom MIDI CC",xy="Custom XY"
        var id:String{rawValue}
    }
    var body:some View {
        VStack(alignment:.leading,spacing:8) {
            Picker("Custom Pad surface",selection:$surface){
                ForEach(Layout.Surface.allCases,id:\.self){Text($0.rawValue).tag($0)}
            }
            performancePanel
            DisclosureGroup("Custom pad designer · offline draft",isExpanded:$expanded) {
            VStack(alignment:.leading,spacing:8) {
                Text("Edit independent surface drafts, then explicitly save or load the selected surface. Saved layouts are offline designs, not active performance routes.").font(.caption).foregroundStyle(.secondary)
                if layouts[surface] == nil {
                    Picker("Starter layout",selection:$preset) {
                        ForEach(CustomSurfacePadPreset.allCases,id:\.self) { Text($0.rawValue).tag($0) }
                    }
                    Stepper("Melodic / starter helper channel "+String(previewChannel+1),value:channelBinding(surface),in:0...15)
                    Button("Create starter draft") {
                        if let layout=preset.layout(surface:surface,channel:previewChannel) {
                            layouts[surface]=layout;select(layout.pads.first);feedback="Starter draft created."
                        } else { feedback="Starter draft could not be validated." }
                    }
                    Text("GM drums use channel 10. Helper channels are fixed in their assignments; edit a pad to change its destination.").font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    Stepper("Columns \(columns)",value:$columns,in:1...16)
                    if surface != .touchBar {Stepper("Rows \(rows)",value:$rows,in:1...16)}
                    Button("Create grid"){
                        if let grid=Layout.grid(surface:surface,columns:columns,rows:surface == .touchBar ? 1:rows){
                            layouts[surface]=grid;select(grid.pads.first);feedback="Grid draft created."
                        } else {feedback="Invalid grid; maximum 64 pads."}
                    }.disabled(layouts[surface] != nil)
                    if layouts[surface] != nil {
                        Button("Reset draft"){request(.reset)}
                    }
                }
                if let library {
                    HStack {
                        Button("Save layout + channel"){request(.save)}
                            .disabled(layouts[surface]==nil || (layouts[surface]==library.layout(for:surface) && previewChannel==library.melodicChannel(for:surface)))
                        Button("Load saved layout + channel"){request(.load)}
                            .disabled(library.layout(for:surface)==nil)
                        Text(library.layout(for:surface)==nil ? "No saved layout":"Saved layout available").font(.caption)
                    }
                } else {
                    Text("Saved layouts could not be read. Original data is preserved; saving is disabled.").font(.caption).foregroundStyle(.orange)
                }
                if let layout=layouts[surface] {
                    DisclosureGroup("Standard MIDI compatibility check") {
                        Stepper("Preview melodic channel \(previewChannel+1)",value:channelBinding(surface),in:0...15)
                        Text(compatibility(layout)).font(.caption).textSelection(.enabled)
                        Text("Offline check only. No endpoint reservation, MIDI send or MPE activation.").font(.caption).foregroundStyle(.secondary)
                    }
                    HStack {
                        Stepper("New pad width \(newWidth)",value:$newWidth,in:100...10000,step:100)
                        if surface != .touchBar {
                            Stepper("Height \(newHeight)",value:$newHeight,in:100...10000,step:100)
                        }
                    }
                    Button("Add pad in empty space"){
                        let id=UUID().uuidString
                        if let next=layout.addingInGap(id:id,label:"New pad",width:newWidth,
                            height:surface == .touchBar ? 10000:newHeight,assignment:.note(60)){
                            layouts[surface]=next
                            select(next.pads.last)
                            feedback="Pad added to a free region."
                        } else {feedback="No matching free region. Resize or remove a pad, or choose a smaller new pad."}
                    }.disabled(layout.pads.count>=64)
                    GeometryReader{geo in
                        ZStack(alignment:.topLeading){
                            RoundedRectangle(cornerRadius:6).strokeBorder(Color.secondary)
                            ForEach(layout.pads){pad in
                                Button{select(pad)} label:{
                                    ZStack{
                                        RoundedRectangle(cornerRadius:3).fill(pad.id==selected ? Color.accentColor.opacity(0.45):Color.secondary.opacity(0.2))
                                        Text(pad.label).font(.caption2).lineLimit(1)
                                    }
                                }.buttonStyle(.plain)
                                .frame(width:max(0,geo.size.width*CGFloat(pad.width)/10000),height:max(0,geo.size.height*CGFloat(pad.height)/10000))
                                .offset(x:geo.size.width*CGFloat(pad.x)/10000,y:geo.size.height*CGFloat(pad.y)/10000)
                            }
                        }.clipped()
                    }.frame(height:surface == .touchBar ? 44:160)
                    Picker("Pad",selection:$selected){
                        Text("Choose pad").tag(String?.none)
                        ForEach(layout.pads){pad in Text(pad.label).tag(Optional(pad.id))}
                    }.onChange(of:selected){id in
                        if let pad=layout.pads.first(where:{$0.id==id}){select(pad)}
                    }
                    if let id=selected {
                        TextField("Label",text:$label)
                        HStack {
                            Stepper("X \(x)",value:$x,in:0...9900,step:100)
                            Stepper("Width \(width)",value:$width,in:100...10000,step:100)
                        }
                        if surface != .touchBar {
                            HStack {
                                Stepper("Y \(y)",value:$y,in:0...9900,step:100)
                                Stepper("Height \(height)",value:$height,in:100...10000,step:100)
                            }
                        }
                        if let pad=layout.pads.first(where:{$0.id==id}) {
                            Text("Current assignment: "+String(describing:pad.assignment)).font(.caption).textSelection(.enabled)
                        }
                        Toggle("Replace musical assignment",isOn:$changeAssignment)
                        if changeAssignment {
                            Picker("Assignment",selection:$kind){ForEach(Kind.allCases){Text($0.rawValue).tag($0)}}
                            if kind == .degree {
                                Stepper("Tuning degree \(note)",value:$note,in:-1408...1408)
                            } else if kind == .note || kind == .drum {
                                Stepper("MIDI note \(note)",value:$note,in:0...127)
                            } else if kind == .chord {
                                TextField("Chord MIDI notes, comma separated",text:$chordNotes)
                            } else if kind == .cc {
                                Stepper("MIDI CC \(cc)",value:$cc,in:0...127)
                            }
                            if kind == .cc || kind == .sustain || kind == .bend {
                                Stepper("MIDI channel \(channel+1)",value:$channel,in:0...15)
                            }
                            if kind == .xy {
                                axisEditor("X",bend:$xyXBend,cc:$xyXCC,channel:$xyXChannel)
                                axisEditor("Y",bend:$xyYBend,cc:$xyYCC,channel:$xyYChannel)
                                Text("X increases right; Y increases upward. Targets must differ.").font(.caption)
                            }
                            if assignment == nil {
                                Text("Invalid or conflicting axis/assignment values.").font(.caption).foregroundStyle(.orange)
                            }
                        }
                        HStack {
                            Button("Apply pad edit"){
                                guard let old=layout.pads.first(where:{$0.id==id}) else{return}
                                let geometry=old.editingGeometry(label:label,x:x,y:surface == .touchBar ? 0:y,width:width,height:surface == .touchBar ? 10000:height)
                                var pad=geometry
                                if changeAssignment {
                                    guard let assignment else{feedback="Invalid musical assignment.";return}
                                    pad=Layout.Pad(id:id,label:label,x:geometry.x,y:geometry.y,width:geometry.width,height:geometry.height,assignment:assignment)
                                }
                                if let next=layout.replacing(pad){layouts[surface]=next;select(pad);feedback="Draft updated."}
                                else {feedback="Edit rejected: overlap, boundary or invalid assignment."}
                            }
                            Button("Remove pad"){
                                if let next=layout.removing(id:id){layouts[surface]=next;select(next.pads.first);feedback="Pad removed."}
                            }.disabled(layout.pads.count<=1)
                        }
                    }
                }
            }.padding(.vertical,6)
            }
            if !feedback.isEmpty {Text(feedback).font(.caption).textSelection(.enabled)}
        }.onChange(of:surface){value in select(layouts[value]?.pads.first);feedback=""}
        .confirmationDialog("Confirm Custom Pad action",
            isPresented:Binding(get:{confirmation != nil},set:{if !$0 {pending=nil;groupConfirmation=nil;pairConfirmation=nil}}),
            titleVisibility:.visible,presenting:confirmation) { operation in
            switch operation {
            case .pair(let request):
                Button(request.action == .save ? "Save both layouts and channels" : "Replace both drafts from saved pair") { applyPair(request) }
            case .group(let request):
                Button("Arm both · Esc stops group") {
                    guard layouts[.trackpad]==request.trackpad,layouts[.magicMouse]==request.mouse,
                          groupTrackpadChannel==request.trackpadChannel,groupMouseChannel==request.mouseChannel else {
                        feedback="Group drafts or channels changed; repeat Arm.";return
                    }
                    studio.startCustomPadGroup(trackpad:request.trackpad,trackpadChannel:request.trackpadChannel,
                        mouse:request.mouse,mouseChannel:request.mouseChannel)
                }
            case .single(let operation):
                Button(operation.action == .arm ? "Arm dedicated MIDI + Escape stop" : operation.action == .reset ? "Reset draft":operation.action == .save ? "Save layout":"Load layout",
                       role:operation.action == .reset ? .destructive:nil){
                    guard surface==operation.surface,layouts[surface]==operation.draft else{
                        feedback="Draft changed; repeat the operation.";return
                    }
                    switch operation.action {
                    case .arm:
                        guard let layout=operation.draft,previewChannel==operation.channel else {
                            feedback="Draft or channel changed; repeat Arm.";return
                        }
                        studio.startCustomPad(layout,channel:operation.channel)
                    case .reset:
                        layouts.removeValue(forKey:surface);selected=nil;feedback="Draft cleared."
                    case .save:
                        guard var current=library,let layout=operation.draft,
                              current.layout(for:surface)==operation.saved,
                              current.melodicChannel(for:surface)==operation.savedChannel,previewChannel==operation.channel else{
                            feedback="Saved layout changed or cannot be read; repeat the operation.";return
                        }
                        guard current.save(layout,melodicChannel:operation.channel) else {feedback="Invalid channel.";return}
                        guard let data=try? JSONEncoder().encode(current) else{feedback="Could not encode layout.";return}
                        storage=data;feedback="Layout and channel saved."
                    case .load:
                        guard let layout=operation.saved,library?.layout(for:surface)==layout,
                              library?.melodicChannel(for:surface)==operation.savedChannel,previewChannel==operation.channel else{
                            feedback="Saved layout changed; repeat the operation.";return
                        }
                        layouts[surface]=layout
                        draftChannels[surface]=operation.savedChannel ?? defaultChannel(surface)
                        select(layout.pads.first);feedback="Saved layout and channel loaded."
                    }
                }
            }
        } message: { operation in
            if case .group = operation {
                Text("Route each dedicated MIDI source independently in your DAW. Both devices require a fresh lift; a fault stops the entire group. No cursor capture.")
            } else if case .pair(let request) = operation {
                Text(request.action == .save ? "This replaces the two saved surface profiles only." : "This replaces the two current drafts, including unsaved changes. It does not start MIDI.")
            }
        }
    }
    private var performancePanel: some View {
        GroupBox("Custom Pad performance · experimental") {
            VStack(alignment:.leading,spacing:8) {
                Text("Trackpad and Magic Mouse only. Standard MIDI on a dedicated virtual source. The layout is frozen when armed; editing a draft cannot reroute active notes. Touch Bar, phone, tablet and tuned layouts remain offline.")
                    .font(.caption).foregroundStyle(.secondary)
                Text(studio.customPadStatus).font(.caption).textSelection(.enabled)
                if studio.customPadDiagnosticRunning {
                    Button("Stop input diagnostic") { studio.stopCustomPad(reason: "Input diagnostic stopped") }
                    Text("No MIDI, haptics or keyboard monitoring. Lift all fingers, hold a finger still for 5 seconds, then release.").font(.caption)
                } else if studio.customPadRunID != nil {
                    Button("Stop Custom Pad",role:.destructive) { studio.stopCustomPad() }
                    if let layout=studio.customPadFrozenLayout, let channel=studio.customPadFrozenChannel {
                        frozenPerformance(layout,channel:channel)
                    }
                    ForEach(studio.customPadGroupLayouts,id:\.surface) { layout in
                        if let channel=studio.customPadGroupChannels[layout.surface] {
                            frozenPerformance(layout,channel:channel)
                        }
                    }
                    Text("Esc stops this performance even outside Studio; the foreground app still receives Escape. Cursor remains free.")
                        .font(.caption)
                } else if !studio.customPadPorts.isEmpty {
                    Button("Retry scoped MIDI recovery") { studio.retryCustomPadRecovery() }
                    Text("Restart is blocked until cleanup and port disposal are confirmed. Identity loss may require resetting the receiving DAW and relaunching Studio.")
                        .font(.caption).foregroundStyle(.orange)
                } else if let layout=layouts[surface], surface == .trackpad || surface == .magicMouse {
                    Stepper("Performance MIDI channel \(previewChannel+1)",value:channelBinding(surface),in:0...15)
                    Button("Arm draft…") { request(.arm) }
                        .disabled((try? CustomSurfaceMixedPlan(layout:layout,melodicChannel:previewChannel)) == nil)
                    Text("Arming explicitly enables the global Escape emergency monitor without pointer capture. Existing Accessibility/Input Monitoring permissions and a fresh physical lift are required. No automatic restart.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text(surface == .trackpad || surface == .magicMouse ?
                         "Create or load a compatible draft first." : "This surface supports offline layout editing only.").font(.caption)
                    Button("Open layout designer") { expanded=true }
                }
                if studio.customPadRunID == nil && !studio.customPadDiagnosticRunning && studio.customPadPorts.isEmpty {
                    DisclosureGroup("Two-device performance · experimental") {
                        HStack {
                            Button("Load saved pair…") { requestPair(.load) }
                                .disabled(library?.nativePair == nil)
                            Button("Save both drafts…") { requestPair(.save) }
                                .disabled(library == nil || draftPair == nil)
                        }
                        if library == nil {Text("Saved library is unreadable; original data preserved.").font(.caption).foregroundStyle(.orange)}
                        if let trackpad=layouts[.trackpad],let mouse=layouts[.magicMouse] {
                            Stepper("Trackpad MIDI channel \(groupTrackpadChannel+1)",value:channelBinding(.trackpad),in:0...15)
                            Stepper("Magic Mouse MIDI channel \(groupMouseChannel+1)",value:channelBinding(.magicMouse),in:0...15)
                            groupRoutingAdvisory(trackpad:trackpad,mouse:mouse)
                            Button("Arm both drafts…") {
                                pending=nil;pairConfirmation=nil
                                groupConfirmation=GroupConfirmation(trackpad:trackpad,mouse:mouse,
                                    trackpadChannel:groupTrackpadChannel,mouseChannel:groupMouseChannel)
                            }.disabled((try? CustomSurfaceMixedPlan(layout:trackpad,melodicChannel:groupTrackpadChannel)) == nil ||
                                        (try? CustomSurfaceMixedPlan(layout:mouse,melodicChannel:groupMouseChannel)) == nil)
                            Text("Melodic channels are shared with each surface's single-device draft. Drums use channel 10; helpers retain their explicit targets. Separate ports; route independently in your DAW. A fault stops both devices.").font(.caption).foregroundStyle(.secondary)
                        } else {
                            Text("Create or load a Trackpad and Magic Mouse draft first.").font(.caption)
                            Button("Open layout designer") { expanded=true }
                        }
                    }
                }
                if studio.customPadRunID == nil && !studio.customPadDiagnosticRunning && studio.customPadPorts.isEmpty && (surface == .trackpad || surface == .magicMouse) {
                    Button("Run 20-second input diagnostic") { studio.startCustomPadDiagnostic(surface) }
                    Text("Collects only aggregate native state and timing counts. No MIDI is sent.").font(.caption).foregroundStyle(.secondary)
                }
                if !studio.customPadEvidenceReport.isEmpty {
                    DisclosureGroup("Native input evidence") {
                        Text(studio.customPadEvidenceReport).font(.caption.monospaced()).textSelection(.enabled)
                    }
                }
                if !studio.customPadMIDITimingReport.isEmpty {
                    DisclosureGroup("Local MIDI timing evidence") {
                        Text(studio.customPadMIDITimingReport).font(.caption.monospaced()).textSelection(.enabled)
                    }
                }
                ForEach(studio.customPadPorts) { port in
                    VStack(alignment:.leading,spacing:2) {
                        Text(port.surface.rawValue + " · " + String(describing:port.phase)).font(.caption.bold())
                        Text(port.name).font(.caption).textSelection(.enabled)
                        Text("Tracked MIDI destinations: \(port.outstanding.count)").font(.caption.monospacedDigit())
                        if port.phase == .live {
                            Text(port.hasNeutralHandshake ? "Physical lift confirmed" : "Waiting for physical lift").font(.caption)
                        }
                    }
                }
            }.frame(maxWidth:.infinity,alignment:.leading)
        }
    }
    /// Render only the armed immutable layout, never the mutable editor draft.
    /// Highlights are local reconciled intent, not acoustic or DAW confirmation.
    private func frozenPerformance(_ layout:Layout,channel:Int)->some View {
        let active=studio.customPadPorts.first(where:{$0.surface==layout.surface && $0.phase == .live})?.activePadIDs ?? []
        return VStack(alignment:.leading,spacing:6) {
            Text("Armed: "+layout.surface.rawValue+" · melodic channel "+String(channel+1)).font(.caption.bold())
            Text("Active logical pads: "+String(active.count)+" / "+String(layout.pads.count)).font(.caption.monospacedDigit())
            GeometryReader { geo in
                ZStack(alignment:.topLeading) {
                    RoundedRectangle(cornerRadius:6).strokeBorder(Color.secondary)
                    ForEach(layout.pads) { pad in
                        let on=active.contains(pad.id)
                        ZStack {
                            RoundedRectangle(cornerRadius:3).fill(on ? Color.accentColor.opacity(0.5):Color.secondary.opacity(0.15))
                            RoundedRectangle(cornerRadius:3).strokeBorder(on ? Color.accentColor:Color.secondary.opacity(0.5),lineWidth:on ? 2:1)
                            HStack(spacing:2) {
                                if on { Image(systemName:"circle.fill").font(.system(size:7)) }
                                Text(pad.label).font(.caption2).lineLimit(1)
                            }.padding(2)
                        }
                        .frame(width:max(0,geo.size.width*CGFloat(pad.width)/10000),height:max(0,geo.size.height*CGFloat(pad.height)/10000))
                        .offset(x:geo.size.width*CGFloat(pad.x)/10000,y:geo.size.height*CGFloat(pad.y)/10000)
                        .accessibilityLabel(pad.label)
                        .accessibilityValue(on ? "Active":"Inactive")
                    }
                }.clipped()
            }.frame(height:160)
            Text("Read-only frozen map. Highlight = locally reconciled pad, not DAW acknowledgement.").font(.caption).foregroundStyle(.secondary)
        }
    }
    @ViewBuilder private func groupRoutingAdvisory(trackpad:Layout,mouse:Layout)->some View {
        if let a=try? CustomSurfaceMixedPlan(layout:trackpad,melodicChannel:groupTrackpadChannel),
           let b=try? CustomSurfaceMixedPlan(layout:mouse,melodicChannel:groupMouseChannel) {
            let overlap=a.overlapIfMerged(with:b)
            if !overlap.channels.isEmpty {
                let names=overlap.channels.sorted().map{String($0+1)}.joined(separator:", ")
                Label("If your DAW merges these sources: shared channels \(names); \(overlap.destinations.count) identical MIDI targets. Channel-wide controls can affect both instruments.",systemImage:"exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
            } else {
                Text("No shared MIDI channels in the current drafts. Independent receiver routing is still required.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
    private func compatibility(_ layout:Layout)->String {
        do {
            let plan=try CustomSurfaceMixedPlan(layout:layout,melodicChannel:previewChannel)
            let channels=Set(plan.destinations.map(\.channel)).sorted().map{String($0+1)}.joined(separator:", ")
            return "Standard MIDI plan valid: \(plan.destinations.count) distinct targets; channels \(channels). Exclusive endpoint required."
        } catch CustomSurfaceMixedPlan.Failure.channelConflict {
            return "Channel conflict: melodic notes and GM drums cannot share channel 10 in this plan."
        } catch CustomSurfaceMixedPlan.Failure.unsupportedPad(let id) {
            let name=layout.pads.first(where:{$0.id==id})?.label ?? id
            return "Unsupported in standard MIDI plan: "+name+". A tuned or dedicated switch route is required."
        } catch CustomSurfaceMixedPlan.Failure.duplicateContinuousTarget(let target) {
            let name=target.kind == .pitchBend ? "Pitch bend":"CC "+String(target.number)
            return "Duplicate continuous target: "+name+", channel "+String(target.channel+1)+"."
        } catch {return "Standard MIDI plan could not be validated."}
    }
    private func axisEditor(_ axis:String,bend:Binding<Bool>,cc:Binding<Int>,channel:Binding<Int>)->some View {
        VStack(alignment:.leading,spacing:4) {
            Text(axis+" axis").font(.caption).bold()
            Toggle("Pitch bend instead of CC",isOn:bend)
            if !bend.wrappedValue {
                Stepper("CC \(cc.wrappedValue)",value:cc,in:0...119)
            }
            Stepper("MIDI channel \(channel.wrappedValue+1)",value:channel,in:0...15)
        }
    }
    private var assignment:Layout.Assignment? {
        let result:Layout.Assignment
        switch kind {
        case .note:result = .note(note)
        case .drum:result = .drum(note)
        case .degree:result = .degree(note)
        case .chord:
            let parts=chordNotes.split(separator:",",omittingEmptySubsequences:false)
            let notes=parts.compactMap{Int($0.trimmingCharacters(in:.whitespaces))}
            guard parts.count==notes.count else{return nil}
            result = .chord(notes)
        case .sustain:result = .helper(.init(.sustain,channel:channel))
        case .bend:result = .helper(.init(.pitchBend,channel:channel))
        case .cc:result = .helper(.init(.controlChange,channel:channel,number:cc))
        case .xy:
            let x=xyXBend ? SensorDestination(.pitchBend,channel:xyXChannel):SensorDestination(.controlChange,channel:xyXChannel,number:xyXCC)
            let y=xyYBend ? SensorDestination(.pitchBend,channel:xyYChannel):SensorDestination(.controlChange,channel:xyYChannel,number:xyYCC)
            result = .xy(x,y)
        }
        return result.isValid ? result:nil
    }
    private func select(_ pad:Layout.Pad?){
        selected=pad?.id
        changeAssignment=false
        guard let pad else{return}
        channel=0
        xyXCC=1;xyYCC=11;xyXChannel=0;xyYChannel=0;xyXBend=false;xyYBend=false
        label=pad.label;x=pad.x;y=pad.y;width=pad.width;height=pad.height
        switch pad.assignment {
        case .note(let n):kind = .note;note=n
        case .drum(let n):kind = .drum;note=n
        case .degree(let n):kind = .degree;note=n
        case .helper(let target):
            channel=target.channel
            if target.kind == .sustain {kind = .sustain}
            else if target.kind == .controlChange {kind = .cc;cc=target.number}
            else {kind = .bend}
        case .xy(let x,let y):
            kind = .xy;xyXChannel=x.channel;xyYChannel=y.channel
            xyXBend=x.kind == .pitchBend;xyYBend=y.kind == .pitchBend
            if !xyXBend {xyXCC=x.number}
            if !xyYBend {xyYCC=y.number}
        case .chord(let notes):kind = .chord;chordNotes=notes.map(String.init).joined(separator:", ")
        }
    }
}
#endif
