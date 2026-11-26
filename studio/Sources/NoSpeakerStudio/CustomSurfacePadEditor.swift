#if os(macOS)
import SwiftUI
import NoSpeakerCore

/// Offline editor. No controller, MIDI or capture callbacks.
struct CustomSurfacePadEditor:View {
    typealias Layout=CustomSurfacePadLayout
    @State private var expanded=false
    @State private var surface:Layout.Surface = .trackpad
    @State private var layouts:[Layout.Surface:Layout]=[:]
    @AppStorage("TIHULU.customSurfaceLayouts.v1") private var storage=Data()
    @State private var pending:Pending?
    private struct Pending:Identifiable {
        enum Action:String {case save,load,reset}
        let action:Action
        let surface:Layout.Surface
        let draft:Layout?
        let saved:Layout?
        var id: String {action.rawValue+surface.rawValue}
    }
    private func request(_ action:Pending.Action) {
        pending=Pending(action:action,surface:surface,draft:layouts[surface],saved:library?.layout(for:surface))
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
    @State private var feedback=""
    @State private var newWidth=1000
    @State private var newHeight=2500
    private enum Kind:String,CaseIterable,Identifiable {
        case note="Note",drum="Drum",degree="Tuning degree",chord="Chord",sustain="Sustain",bend="Pitch bend",cc="Custom MIDI CC",xy="XY (CC1 / CC11)"
        var id:String{rawValue}
    }
    var body:some View {
        DisclosureGroup("Custom pad designer · offline draft",isExpanded:$expanded) {
            VStack(alignment:.leading,spacing:8) {
                Text("Edit independent surface drafts, then explicitly save or load the selected surface. Saved layouts are offline designs, not active performance routes.").font(.caption).foregroundStyle(.secondary)
                Picker("Surface",selection:$surface){
                    ForEach(Layout.Surface.allCases,id:\.self){Text($0.rawValue).tag($0)}
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
                        Button("Save layout"){request(.save)}
                            .disabled(layouts[surface]==nil || layouts[surface]==library.layout(for:surface))
                        Button("Load saved layout"){request(.load)}
                            .disabled(library.layout(for:surface)==nil)
                        Text(library.layout(for:surface)==nil ? "No saved layout":"Saved layout available").font(.caption)
                    }
                } else {
                    Text("Saved layouts could not be read. Original data is preserved; saving is disabled.").font(.caption).foregroundStyle(.orange)
                }
                if let layout=layouts[surface] {
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
                            if kind == .cc || kind == .sustain || kind == .bend || kind == .xy {
                                Stepper("MIDI channel \(channel+1)",value:$channel,in:0...15)
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
                if !feedback.isEmpty {Text(feedback).font(.caption)}
            }.padding(.vertical,6)
        }.onChange(of:surface){value in select(layouts[value]?.pads.first);feedback=""}
        .confirmationDialog("Confirm surface layout change",isPresented:Binding(get:{pending != nil},set:{if !$0 {pending=nil}}),titleVisibility:.visible,presenting:pending){operation in
            Button(operation.action == .reset ? "Reset draft":operation.action == .save ? "Save layout":"Load layout",
                   role:operation.action == .reset ? .destructive:nil){
                guard surface==operation.surface,layouts[surface]==operation.draft else{
                    feedback="Draft changed; repeat the operation.";return
                }
                switch operation.action {
                case .reset:
                    layouts.removeValue(forKey:surface);selected=nil;feedback="Draft cleared."
                case .save:
                    guard var current=library,let layout=operation.draft,
                          current.layout(for:surface)==operation.saved else{
                        feedback="Saved layout changed or cannot be read; repeat the operation.";return
                    }
                    current.save(layout)
                    guard let data=try? JSONEncoder().encode(current) else{feedback="Could not encode layout.";return}
                    storage=data;feedback="Layout saved."
                case .load:
                    guard let layout=operation.saved,library?.layout(for:surface)==layout else{
                        feedback="Saved layout changed; repeat the operation.";return
                    }
                    layouts[surface]=layout;select(layout.pads.first);feedback="Saved layout loaded."
                }
            }
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
        case .xy:result = .xy(.init(.controlChange,channel:channel,number:1),.init(.controlChange,channel:channel,number:11))
        }
        return result.isValid ? result:nil
    }
    private func select(_ pad:Layout.Pad?){
        selected=pad?.id
        changeAssignment=false
        guard let pad else{return}
        channel=0
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
        case .xy(let x,_):kind = .xy;channel=x.channel
        case .chord(let notes):kind = .chord;chordNotes=notes.map(String.init).joined(separator:", ")
        }
    }
}
#endif
