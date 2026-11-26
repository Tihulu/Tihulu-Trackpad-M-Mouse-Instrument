#if os(macOS)
import SwiftUI
import NoSpeakerCore

/// Offline source-key guide; never subscribes to MIDI or advertises
/// live note feedback. The same mapping model supplies labels and details.
struct PhysicalKeyboardScalePreview: View {
    let scale:CustomScale
    private enum Layout:String,CaseIterable,Identifiable {
        case scale="Selected scale", white="White keys only", edo="EDO · all keys"
        var id:String{rawValue}
    }
    @State private var expanded=false
    @State private var layout:Layout = .scale
    @State private var root=60
    @State private var edo=24
    @State private var selected:Int?
    private var plan:PhysicalKeyboardScaleMap? {
        switch layout {
        case .scale:return .legacy(scale,inputRoot:60,outputRoot:root)
        case .white:
            guard let t=MicrotonalKeyboardTuning(degrees:scale.degreeCents.map(Double.init),rootMIDI:root) else{return nil}
            return .init(tuning:t,inputRoot:60,layout:.whiteKeys)
        case .edo:
            guard let t=MicrotonalKeyboardTuning.edo(edo,rootMIDI:root) else{return nil}
            return .init(tuning:t,inputRoot:60,layout:.allKeys)
        }
    }
    private let white=[0,2,4,5,7,9,11,12]
    private let black=[(1,1),(3,2),(6,4),(8,5),(10,6)]
    private let names=["C","C♯","D","D♯","E","F","F♯","G","G♯","A","A♯","B"]
    var body:some View {
        DisclosureGroup("USB MIDI keyboard · scale map preview",isExpanded:$expanded) {
            VStack(alignment:.leading,spacing:8) {
                Text("Offline mapping only · no MIDI input or output").font(.caption).foregroundStyle(.secondary)
                Picker("Key mapping",selection:$layout){
                    ForEach(Layout.allCases){Text($0.rawValue).tag($0)}
                }
                Stepper("Output root MIDI \(root)",value:$root,in:36...84)
                if layout == .edo {
                    Picker("Equal octave divisions",selection:$edo){
                        ForEach([12,19,24,31,53],id:\.self){Text("\($0)-EDO").tag($0)}
                    }
                }
                if let plan {
                    GeometryReader { geo in
                        let cell=geo.size.width/8
                        ZStack(alignment:.topLeading){
                            ForEach(white,id:\.self){offset in
                                if let index=white.firstIndex(of:offset){
                                    keyButton(60+offset,plan:plan,black:false)
                                        .frame(width:max(1,cell-2),height:geo.size.height)
                                        .offset(x:CGFloat(index)*cell+1)
                                }
                            }
                            ForEach(black.indices,id:\.self){i in
                                let (offset,boundary)=black[i]
                                keyButton(60+offset,plan:plan,black:true)
                                    .frame(width:cell*0.64,height:geo.size.height*0.61)
                                    .offset(x:CGFloat(boundary)*cell-cell*0.32)
                            }
                        }
                    }.frame(height:112)
                    Text("Blue: mapped · gray: muted in this mapping. Click a physical key to inspect its target pitch.")
                        .font(.caption).foregroundStyle(.secondary)
                    if let selected,let key=plan.key(selected) {
                        if let pitch=key.pitch {
                            Text("Input \(label(selected)) · degree \(pitch.degree+1) · \(pitch.centsFromRoot,format:.number.precision(.fractionLength(2)))¢ · \(pitch.frequency,format:.number.precision(.fractionLength(2))) Hz")
                                .font(.caption.monospacedDigit())
                        } else {
                            Text("Input \(label(selected)) · outside mapping / muted").font(.caption)
                        }
                    }
                    if layout == .edo {
                        Text("Physical semitone keys advance one tuning step, not one semitone. The physical C-to-C span is not necessarily an octave.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } else {Text("Invalid scale mapping").foregroundStyle(.orange)}
            }.padding(.vertical,4)
        }
    }
    private func label(_ note:Int)->String {names[note%12]+String(note/12-1)}
    private func keyButton(_ note:Int,plan:PhysicalKeyboardScaleMap,black:Bool)->some View {
        let mapped=plan.key(note)?.isMapped==true
        return Button {selected=note} label:{
            ZStack(alignment:.bottom){
                RoundedRectangle(cornerRadius:4)
                    .fill(mapped ? Color.blue.opacity(black ? 0.75:0.4) : black ? Color(white:0.17):Color(white:0.78))
                RoundedRectangle(cornerRadius:4)
                    .strokeBorder(selected==note ? Color.accentColor:Color.secondary.opacity(0.5),lineWidth:selected==note ? 2:1)
                Text(names[note%12]).font(.caption2.bold())
                    .foregroundStyle(black ? Color.white:Color.black)
                    .padding(.bottom,5)
            }
        }.buttonStyle(.plain)
            .accessibilityLabel("\(label(note)), \(mapped ? "mapped":"muted")")
            .accessibilityHint("Inspect mapped pitch; no MIDI output")
    }
}
#endif
