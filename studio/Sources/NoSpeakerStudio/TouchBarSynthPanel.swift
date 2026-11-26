#if os(macOS)
import SwiftUI
import NoSpeakerCore

struct TouchBarSynthPanel:View {
    typealias Bank=TouchBarSynthBank
    @EnvironmentObject private var studio:StudioController
    @State private var expanded=false
    @State private var name="Resonance"
    @State private var cc=71
    @State private var style:Bank.Style = .knob
    @State private var low=0
    @State private var high=127
    @State private var neutral=0
    @State private var inheritChannel=true
    @State private var channel=0
    @State private var inverted=false
    @State private var curve:Bank.Curve = .linear
    @State private var editing:UUID?
    @State private var feedback=""
    var body:some View {
        GroupBox("Synth controls · MIDI CC") {
            VStack(alignment:.leading,spacing:8) {
                let bank=studio.touchBarProfile.effectiveSynthBank
                Text("Custom parameters can inherit the profile MIDI channel or use an explicit channel. Start the MIDI bridge explicitly and assign the receiving synth or DAW parameter via MIDI Learn. The label is not a plugin parameter binding. Higher-priority existing owners may override a CC.").font(.caption).foregroundStyle(.secondary)
                Text(studio.touchBarSynthAvailable ? "MIDI bridge running · custom controls available":"MIDI output unavailable · configure and start the standard MIDI bridge").font(.caption)
                if !bank.controls.isEmpty {
                    LazyVGrid(columns:[GridItem(.adaptive(minimum:132))],spacing:8) {
                        ForEach(bank.controls){control in
                            TouchBarSynthPerformanceControl(control:control)
                                .id(control.id)
                        }
                    }
                }
                DisclosureGroup("Customize synth parameters",isExpanded:$expanded) {
                    VStack(alignment:.leading,spacing:8) {
                        Text("Up to eight controls. Native Touch Bar items follow the built-in zones by default; macOS customization can reorder them. Reserved selectors, pedals and existing Touch Bar CCs are excluded.").font(.caption).foregroundStyle(.secondary)
                        ForEach(bank.controls){control in
                            HStack{
                                Text("\(control.name) · CC \(control.cc) · Ch \((control.channel ?? studio.touchBarProfile.channel)+1) · \(control.style.rawValue)")
                                Spacer()
                                Button{if let next=bank.moving(id:control.id,delta:-1){apply(next)}} label:{Image(systemName:"arrow.left")}.disabled(bank.controls.first?.id==control.id).accessibilityLabel("Move \(control.name) left")
                                Button{if let next=bank.moving(id:control.id,delta:1){apply(next)}} label:{Image(systemName:"arrow.right")}.disabled(bank.controls.last?.id==control.id).accessibilityLabel("Move \(control.name) right")
                                Button("Edit"){load(control)}
                                Button("Remove",role:.destructive){if let next=bank.removing(id:control.id){apply(next);if editing==control.id {editing=nil}}}
                            }
                        }
                        Menu("Suggested parameters") {
                            ForEach(Bank.presets){preset in
                                Button("\(preset.name) · CC \(preset.cc)"){name=preset.name;cc=preset.cc;neutral=preset.neutral;low=0;high=127}
                            }
                        }
                        TextField("Parameter name",text:$name)
                        Picker("Control",selection:$style){ForEach(Bank.Style.allCases){Text($0.rawValue).tag($0)}}
                        Stepper("MIDI CC \(cc)",value:$cc,in:0...127)
                        HStack {
                            Stepper("Min \(low)",value:$low,in:0...127)
                            Stepper("Max \(high)",value:$high,in:0...127)
                        }
                        Stepper("Reset on Stop \(neutral)",value:$neutral,in:0...127)
                        Toggle("Use profile MIDI channel",isOn:$inheritChannel)
                        if !inheritChannel {Stepper("MIDI channel \(channel+1)",value:$channel,in:0...15)}
                        Toggle("Reverse direction",isOn:$inverted)
                        if style != .toggle {
                            Picker("Response curve",selection:$curve){ForEach(Bank.Curve.allCases){Text($0.rawValue).tag($0)}}
                        }
                        HStack {
                            Button(editing == nil ? "Add control":"Apply edit") {
                                let control=Bank.Control(id:editing ?? UUID(),name:name,cc:cc,style:style,low:low,high:high,neutral:neutral,channel:inheritChannel ? nil:channel,inverted:inverted ? true:nil,curve:curve == .linear ? nil:curve)
                                let next=editing == nil ? bank.adding(control):bank.replacing(control)
                                if let next {apply(next);editing=nil}
                                else {feedback="Invalid name/range, reserved or duplicate CC, or bank full."}
                            }.disabled(studio.groupGamepadsRunning)
                            if editing != nil {Button("Cancel edit"){editing=nil}}
                        }
                        if !feedback.isEmpty {Text(feedback).font(.caption)}
                    }.padding(.vertical,6)
                }
            }.padding(6)
        }
    }
    private func load(_ c:Bank.Control){
        editing=c.id;name=c.name;cc=c.cc;style=c.style;low=c.low;high=c.high;neutral=c.neutral
        inheritChannel=c.channel==nil;channel=c.channel ?? studio.touchBarProfile.channel
        inverted=c.inverted ?? false;curve=c.curve ?? .linear
    }
    private func apply(_ bank:Bank){
        var profile=studio.touchBarProfile;profile.synthBank=bank
        studio.setTouchBarProfile(profile)
        feedback=studio.touchBarProfile.effectiveSynthBank==bank ? "Controls saved.":"Not applied; check session or cleanup status."
    }
}

private struct TouchBarSynthPerformanceControl:View {
    let control:TouchBarSynthBank.Control
    @EnvironmentObject private var studio:StudioController
    @State private var value:Double=0
    @State private var revision:UInt64?
    @State private var knobStart:Double?
    @GestureState private var knobDragging=false
    var body:some View {
        VStack(alignment:.leading,spacing:4) {
            Text(control.name).font(.caption.bold()).lineLimit(1)
            if control.style == .toggle {
                Toggle("CC \(control.cc)",isOn:Binding(get:{value>=0.5},set:{send($0 ? 1:0)}))
                    .toggleStyle(.switch)
            } else if control.style == .knob {
                ZStack {
                    Circle().strokeBorder(Color.secondary.opacity(0.35),lineWidth:2)
                    Circle().trim(from:0,to:value).stroke(Color.accentColor,lineWidth:4).rotationEffect(.degrees(-90))
                    Text(String(control.value(normalized:value) ?? control.neutral)).font(.caption.monospacedDigit())
                }.frame(width:44,height:44)
                .contentShape(Circle())
                .gesture(DragGesture(minimumDistance:0)
                    .updating($knobDragging){_,state,_ in state=true}
                    .onChanged{drag in
                        if knobStart == nil {
                            knobStart=value
                            revision=studio.touchBarGestureEpoch.revision
                        }
                        guard let start=knobStart else{return}
                        let delta=Double(drag.translation.width-drag.translation.height)/150
                        send(min(1,max(0,start+delta)))
                    }
                    .onEnded{_ in knobStart=nil;revision=nil})
                .onChange(of:knobDragging){active in
                    if !active {knobStart=nil;revision=nil}
                }
                .accessibilityElement(children:.ignore)
                .accessibilityLabel(control.name)
                .accessibilityValue(String(control.value(normalized:value) ?? control.neutral))
                .accessibilityAdjustableAction{direction in
                    guard !knobDragging else{return}
                    switch direction {
                    case .increment:send(min(1,value+1/Double(control.high-control.low)))
                    case .decrement:send(max(0,value-1/Double(control.high-control.low)))
                    @unknown default:break
                    }
                }
                .help("Drag up or right to increase; drag down or left to decrease.")
            } else {
                Slider(value:Binding(get:{value},set:{send($0)}),in:0...1,onEditingChanged:{active in
                    revision=active ? studio.touchBarGestureEpoch.revision:nil
                }).accessibilityLabel(control.name)
            }
            Text("Ch \((control.channel ?? studio.touchBarProfile.channel)+1) · CC \(control.cc) · \(control.value(normalized:value) ?? control.neutral)").font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
        }.padding(6)
         .disabled(!studio.touchBarSynthAvailable)
         .onAppear{value=control.initialPosition}
         .onChange(of:studio.touchBarGestureEpoch.revision){_ in value=control.initialPosition}
    }
    private func send(_ normalized:Double){
        if studio.touchBarSynthValue(id:control.id,normalized:normalized,revision:revision){value=normalized}
    }
}
#endif
