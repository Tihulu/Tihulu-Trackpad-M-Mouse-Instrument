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
    @State private var confirmLoad=false
    @State private var confirmSave=false
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
    @State private var feedback=""
    private enum Kind:String,CaseIterable,Identifiable {
        case note="Note",drum="Drum",degree="Tuning degree",sustain="Sustain",bend="Pitch bend",xy="XY (CC1 / CC11)"
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
                        Button("Reset draft"){layouts.removeValue(forKey:surface);selected=nil;feedback="Draft cleared."}
                    }
                }
                if let library {
                    HStack {
                        Button("Save layout"){confirmSave=true}
                            .disabled(layouts[surface]==nil || layouts[surface]==library.layout(for:surface))
                        Button("Load saved layout"){confirmLoad=true}
                            .disabled(library.layout(for:surface)==nil)
                        Text(library.layout(for:surface)==nil ? "No saved layout":"Saved layout available").font(.caption)
                    }
                } else {
                    Text("Saved layouts could not be read. Original data is preserved; saving is disabled.").font(.caption).foregroundStyle(.orange)
                }
                if let layout=layouts[surface] {
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
                        Picker("Assignment",selection:$kind){ForEach(Kind.allCases){Text($0.rawValue).tag($0)}}
                        if kind == .note || kind == .drum || kind == .degree {
                            Stepper("Note / degree \(note)",value:$note,in:0...127)
                        }
                        HStack {
                            Button("Apply pad edit"){
                                let pad=Layout.Pad(id:id,label:label,x:x,y:surface == .touchBar ? 0:y,width:width,height:surface == .touchBar ? 10000:height,assignment:assignment)
                                if let next=layout.replacing(pad){layouts[surface]=next;feedback="Draft updated."}
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
        .confirmationDialog("Save this offline surface layout?",isPresented:$confirmSave,titleVisibility:.visible){
            Button("Save"){
                guard var library,let layout=layouts[surface] else{return}
                library.save(layout)
                guard let data=try? JSONEncoder().encode(library) else{feedback="Could not encode layout.";return}
                storage=data;feedback="Layout saved."
            }
        }
        .confirmationDialog("Replace current draft with saved layout?",isPresented:$confirmLoad,titleVisibility:.visible){
            Button("Load"){
                guard let layout=library?.layout(for:surface) else{return}
                layouts[surface]=layout;select(layout.pads.first);feedback="Saved layout loaded."
            }
        }
    }
    private var assignment:Layout.Assignment {
        switch kind {
        case .note:return .note(note)
        case .drum:return .drum(note)
        case .degree:return .degree(note)
        case .sustain:return .helper(.init(.sustain))
        case .bend:return .helper(.init(.pitchBend))
        case .xy:return .xy(.init(.controlChange,number:1),.init(.controlChange,number:11))
        }
    }
    private func select(_ pad:Layout.Pad?){
        selected=pad?.id
        guard let pad else{return}
        label=pad.label;x=pad.x;y=pad.y;width=pad.width;height=pad.height
        switch pad.assignment {
        case .note(let n):kind = .note;note=n
        case .drum(let n):kind = .drum;note=n
        case .degree(let n):kind = .degree;note=n
        case .helper(let target):kind=target.kind == .sustain ? .sustain:.bend
        case .xy:kind = .xy
        case .chord:kind = .note
        }
    }
}
#endif
