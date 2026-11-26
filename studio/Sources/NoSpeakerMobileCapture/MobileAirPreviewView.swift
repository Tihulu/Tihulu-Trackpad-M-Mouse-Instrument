#if os(iOS)
import SwiftUI
import Combine
import NoSpeakerCore

/// A sensor-only diagnostic stage for an iOS/iPadOS host app. No connection,
/// MIDI endpoint or note emission is opened by this view.
@MainActor public struct MobileAirPreviewView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var backend:MobileAirSensorSource.Backend = .rearCamera
    @State private var mode:MobileAirMode = .pinchKeys
    @State private var role:MobileAirHandRole = .single
    @State private var sensorOrientation:MobileSensorOrientation = .up
    @State private var musicalOrientation:AirControlOrientation = .upright
    @State private var mirror=false
    @State private var near=0.25
    @State private var far=0.85
    @State private var source:MobileAirSensorSource?
    @State private var projection:MobileAirCaptureProjection?
    @State private var pending=false
    @State private var generation=UUID()
    @State private var output=MobileAirOutput()
    @State private var sample:AirHandSample?
    @State private var depth:Double?
    @State private var status="Stopped · sensor-only preview"
    private let timer=Timer.publish(every:0.05,on:.main,in:.common).autoconnect()

    public init() {}
    private var busy:Bool {pending || source != nil}
    private var valid:Bool {
        (!mode.usesDepth || backend == .lidar) &&
        (backend != .lidar || MobileAirSensorSource.hasLiDAR) &&
        (mode != .chords || role != .single) && far-near >= 0.1
    }

    public var body:some View {
        ScrollView {
            VStack(alignment:.leading,spacing:16) {
                Text("TIHULU · Air stage").font(.largeTitle.bold())
                Text("Local sensor preview — no MIDI or network connection").font(.subheadline).foregroundStyle(.secondary)
                HStack {
                    Label(MobileAirSensorSource.hasLiDAR ? "LiDAR available":"Camera only",systemImage:"sensor")
                    Spacer()
                    Text(status).font(.caption).multilineTextAlignment(.trailing)
                }
                Group {
                    Picker("Sensor",selection:$backend) {
                        Text("Rear camera").tag(MobileAirSensorSource.Backend.rearCamera)
                        Text("Front camera").tag(MobileAirSensorSource.Backend.frontCamera)
                        if MobileAirSensorSource.hasLiDAR {Text("Rear camera + LiDAR").tag(MobileAirSensorSource.Backend.lidar)}
                    }
                    Picker("Instrument / helper",selection:$mode) {
                        ForEach(MobileAirMode.allCases) {m in Text(m.rawValue).tag(m)}
                    }
                    Picker("Performing hand",selection:$role) {
                        ForEach(MobileAirHandRole.allCases) {r in Text(r.rawValue.capitalized).tag(r)}
                    }
                    Picker("Sensor image orientation",selection:$sensorOrientation) {
                        Text("0°").tag(MobileSensorOrientation.up)
                        Text("90°").tag(MobileSensorOrientation.right)
                        Text("180°").tag(MobileSensorOrientation.down)
                        Text("270°").tag(MobileSensorOrientation.left)
                    }
                    Picker("Control orientation",selection:$musicalOrientation) {
                        ForEach(AirControlOrientation.allCases) {o in Text(o.rawValue).tag(o)}
                    }
                    Toggle("Mirror control X",isOn:$mirror)
                    if backend == .lidar {
                        VStack(alignment:.leading) {
                            Text("Near: \(near,format:.number.precision(.fractionLength(2))) m")
                            Slider(value:$near,in:0.1...1.5,step:0.05)
                            Text("Far: \(far,format:.number.precision(.fractionLength(2))) m")
                            Slider(value:$far,in:0.2...3,step:0.05)
                        }
                    }
                }.disabled(busy)
                if !valid {
                    Text("Select a supported sensor, valid range and a distinct performing hand for chords.").foregroundStyle(.orange)
                }
                GeometryReader {geo in
                    ZStack {
                        RoundedRectangle(cornerRadius:16).fill(Color.secondary.opacity(0.12))
                        Path {p in
                            p.move(to:CGPoint(x:geo.size.width/2,y:0));p.addLine(to:CGPoint(x:geo.size.width/2,y:geo.size.height))
                            p.move(to:CGPoint(x:0,y:geo.size.height/2));p.addLine(to:CGPoint(x:geo.size.width,y:geo.size.height/2))
                        }.stroke(.secondary.opacity(0.5),style:StrokeStyle(lineWidth:1,dash:[5,5]))
                        if let sample {
                            Circle().fill(.cyan).frame(width:22,height:22)
                                .position(x:sample.x*geo.size.width,y:(1-sample.y)*geo.size.height)
                        } else {Text("No reliable hand").foregroundStyle(.secondary)}
                    }
                }.frame(height:210).accessibilityLabel("Derived hand position; no camera image")
                if let depth {
                    Text("Measured palm depth: \(depth,format:.number.precision(.fractionLength(2))) m")
                } else {Text("Depth: unavailable").foregroundStyle(.secondary)}
                if let level=output.level {
                    ProgressView(value:level).accessibilityLabel("Projected helper level")
                    Text("Helper: \(Int(level*100))%")
                } else {Text("Helper released").foregroundStyle(.secondary)}
                let active=(0..<25).filter { output.keys & (1<<$0) != 0 }
                Text(active.isEmpty ? "All preview keys released":"Logical keys: "+active.map {String($0+1)}.joined(separator:", "))
                HStack {
                    Button("Start sensors",action:start).buttonStyle(.borderedProminent).disabled(busy || !valid || scenePhase != .active)
                    Button("Stop / release") { stop("Stopped") }.buttonStyle(.bordered).disabled(!busy)
                }
                Text("No image is displayed, saved or transmitted. This panel does not play sound. A signed companion and authenticated MIDI connection are separate acceptance gates.").font(.caption).foregroundStyle(.secondary)
            }.padding().frame(maxWidth:640).frame(maxWidth:.infinity)
        }
        .onReceive(timer) {_ in poll()}
        .onChange(of:scenePhase) {_,phase in if phase != .active {stop("App inactive · stopped")} }
        .onDisappear {stop("View closed")}
    }
    private func start() {
        guard !busy,valid,scenePhase == .active else {return}
        let ticket=UUID();generation=ticket;pending=true;status="Waiting for camera permission"
        Task { @MainActor in
            let granted=await MobileAirSensorSource.requestCameraPermission()
            guard generation==ticket,pending else {return}
            guard granted,scenePhase == .active else {stop("Camera permission denied or app inactive");return}
            // Synthetic logical key authorization for the isolated preview only.
            guard let next=MobileAirCaptureProjection(mode:mode,keys:(1<<25)-1,role:role,
                orientation:musicalOrientation,mirrorX:mirror,near:near,far:far) else {stop("Invalid setup");return}
            let capture=MobileAirSensorSource()
            projection=next;source=capture;pending=false;status="Starting sensors"
            capture.start(backend:backend,orientation:sensorOrientation)
        }
    }
    private func stop(_ message:String) {
        generation=UUID();pending=false
        source?.stop();source=nil;projection=nil
        output = .init();sample=nil;depth=nil;status=message
    }
    private func poll() {
        guard let source,var p=projection else {return}
        let now=MobileAirSensorSource.now
        for event in source.drain() {
            switch event {
            case .ready:status="Sensors started · waiting for hand"
            case .fault(let message):stop(message);return
            case .frame(let frame):
                output=p.receive(frame,now:now)
                let observation:MobileAirObservation?
                switch role {case .single:observation=frame.single;case .left:observation=frame.left;case .right:observation=frame.right}
                if frame.time.isFinite,now>=frame.time,now-frame.time<0.15 {
                    sample=observation?.sample?.oriented(musicalOrientation,mirrorX:mirror)
                    depth=observation?.depth
                } else {sample=nil;depth=nil}
            }
        }
        if let release=p.expire(now:now) {output=release;sample=nil;depth=nil}
        projection=p
    }
}
#endif
