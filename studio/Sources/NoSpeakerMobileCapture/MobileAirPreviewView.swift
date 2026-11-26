#if os(iOS)
import SwiftUI
import Combine
import NoSpeakerCore

/// Local preview and explicitly paired Mac performance share one camera owner.
@MainActor public struct MobileAirPreviewView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var useMac = false
    @State private var pageAddress = ""
    @State private var invitation = ""
    @State private var helperIndex = 0
    @State private var socket: MobileLANSocket?
    @State private var assignment: MobileLANCapabilities.Manifest?
    @State private var connectionStatus = ""
    @State private var scanning = false
    @State private var touchPreview = false
    @State private var liveTouchID:UUID?
    @State private var liveTouchMask:Int?
    @State private var askingPermission = false
    @State private var backend:MobileAirSensorSource.Backend = .rearCamera
    @State private var cameras:[MobileAirSensorSource.CameraChoice]=[]
    @State private var cameraID:String=""
    @State private var zoom=1.0
    @State private var retiring:MobileAirSensorSource?
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
    @State private var status="Stopped"
    private let timer=Timer.publish(every:0.05,on:.main,in:.common).autoconnect()

    public init() {}
    private var busy:Bool {liveTouchID != nil || pending || source != nil || retiring != nil}
    private var configurationLocked: Bool { busy || socket != nil || scanning || askingPermission || touchPreview }
    private var instrumentLocked: Bool {busy || scanning || askingPermission || (socket != nil && assignment == nil)}
    private var playableAssignment: Bool {
        guard useMac else { return true }
        guard let assignment, mode.isHelper == (assignment.piano == 0) else { return false }
        return MobileAirCaptureProjection(mode: mode, keys: assignment.piano, role: role,
            orientation: musicalOrientation, mirrorX: mirror, near: near, far: far) != nil
    }
    private var selectedCamera:MobileAirSensorSource.CameraChoice? {cameras.first {$0.id==cameraID}}
    private func refreshCameras() {
        cameras=MobileAirSensorSource.cameras(for:backend)
        cameraID=cameras.first?.id ?? ""
        zoom=selectedCamera?.zoom.defaultFactor ?? 1
    }
    private var valid:Bool {
        (backend == .lidar || selectedCamera?.zoom.contains(zoom) == true) &&
        (!mode.usesDepth || backend == .lidar) &&
        (backend != .lidar || MobileAirSensorSource.hasLiDAR) &&
        (mode != .chords || role != .single) && far-near >= 0.1
    }

    public var body:some View {
        ScrollView {
            VStack(alignment:.leading,spacing:16) {
                Text("TIHULU · Air stage").font(.largeTitle.bold())
                Button("Touch piano · local preview") { touchPreview=true }.disabled(configurationLocked)
                Picker("Output", selection: $useMac) {
                    Text("Local preview").tag(false)
                    Text("Paired Mac").tag(true)
                }.pickerStyle(.segmented).disabled(configurationLocked)
                if useMac { pairingPanel }
                if let id=liveTouchID,let mask=liveTouchMask {
                    MobileTouchPianoPreview(authorized:mask,live:{ sample in
                        guard liveTouchID==id,scenePhase == .active,let socket,
                              socket.status().assignment?.piano==mask else{return false}
                        socket.offer(sample.output,observedAt:sample.ownerAt)
                        return socket.status().phase == .ready
                    },stopped:{
                        if liveTouchID==id{stop("Touch piano released · disconnected")}
                    }).id(id).frame(height:360)
                    Button("Release / disconnect"){stop("Touch piano released")}
                } else if useMac,assignment?.piano ?? 0 != 0 {
                    Button("Open assigned touch piano",action:openTouchPiano).disabled(busy || scanning || askingPermission || scenePhase != .active)
                }
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
                    if backend != .lidar {
                        Picker("Camera / lens",selection:$cameraID) {
                            ForEach(cameras) {c in Text(c.name).tag(c.id)}
                        }
                        if let range=selectedCamera?.zoom {
                            Text("Lens-relative zoom: \(zoom,format:.number.precision(.fractionLength(2)))×")
                            if range.maximum>range.minimum {
                                Slider(value:$zoom,in:range.minimum...range.maximum)
                                HStack {
                                    Button("−") {zoom=max(range.minimum,zoom/1.25)}
                                    Button("+") {zoom=min(range.maximum,zoom*1.25)}
                                    Button("Reset") {zoom=range.defaultFactor}
                                }
                                if !range.switches.isEmpty {
                                    Text("Lens switch factors: "+range.switches.map {String(format:"%.2f×",$0)}.joined(separator:", ")).font(.caption)
                                }
                            }
                        }
                    } else {Text("LiDAR: native calibrated field of view · zoom locked").font(.caption)}
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
                }.disabled(instrumentLocked)
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
                    Button(useMac ? "Start playing" : "Start sensors", action: start).buttonStyle(.borderedProminent)
                        .disabled(busy || scanning || askingPermission || !valid || !playableAssignment || scenePhase != .active)
                    Button("Stop / release") { stop("Stopped") }.buttonStyle(.bordered).disabled(!busy)
                    if useMac,socket != nil {
                        Button("Pause / change instrument",action:pauseInstrument)
                            .buttonStyle(.bordered).disabled(assignment == nil || (source == nil && !pending))
                    }
                }
                Text(useMac ? "Your hand position and depth are processed on this device. The Mac receives assigned keys or helper levels." : "Preview keys and helper levels on this device.").font(.caption).foregroundStyle(.secondary)
            }.padding().frame(maxWidth:640).frame(maxWidth:.infinity)
        }
        .onAppear {if !busy {refreshCameras()}}
        .onChange(of:backend) {_,_ in if !busy {refreshCameras()}}
        .onChange(of:cameraID) {_,_ in if !busy {zoom=selectedCamera?.zoom.defaultFactor ?? 1}}
        .sheet(isPresented: $touchPreview) {
            NavigationStack {
                MobileTouchPianoPreview()
                    .navigationTitle("Touch piano")
                    .toolbar { Button("Done") {touchPreview=false} }
            }
        }
        .sheet(isPresented: $scanning) {
            NavigationStack {
                MobileAddressScanner { address in
                    scanning = false
                    if let address, MobileLANEndpoint(pageAddress: address) != nil {
                        pageAddress = address
                        invitation = ""
                        connectionStatus = "Address scanned. Enter the separate invitation from the Mac."
                    } else {
                        connectionStatus = "Scan the Mac’s controller address QR or type the address."
                    }
                }
                .navigationTitle("Scan Mac address")
                .toolbar { Button("Cancel") { scanning = false } }
            }
        }
        .onReceive(timer) {_ in poll()}
        .onChange(of:scenePhase) {_,phase in
            if phase != .active { scanning = false; touchPreview=false; stop("App inactive · stopped") }
        }
        .onDisappear {stop("View closed")}
    }
    private var pairingPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("Mac controller address", text: $pageAddress)
                .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                .textFieldStyle(.roundedBorder).disabled(configurationLocked)
            Button("Scan Mac address QR") {
                guard cameraPermissionForPairing() else { return }
                scanning = true
            }.disabled(configurationLocked)
            SecureField("One-time invitation from Mac", text: $invitation)
                .textInputAutocapitalization(.never).autocorrectionDisabled().privacySensitive()
                .textFieldStyle(.roundedBorder).disabled(configurationLocked)
            if mode.isHelper {
                Picker("Mac helper lane", selection: $helperIndex) {
                    ForEach(0..<3) { index in Text("Pedal " + String(index + 1)).tag(index) }
                }.disabled(configurationLocked)
            }
            if socket == nil {
                Button("Connect to Mac", action: connect)
                    .disabled(configurationLocked || !valid || MobileLANEndpoint(pageAddress: pageAddress) == nil ||
                              MobileLANEndpoint.invitationBytes(invitation) == nil || scenePhase != .active)
            } else {
                Button("Disconnect and release") { stop("Disconnected") }
            }
            if let assignment {
                if assignment.piano == 0 {
                    Text("Mac assigned pedal " + String(helperIndex + 1))
                } else {
                    let keys = (0..<25).filter { assignment.piano & (1 << $0) != 0 }
                    Text("Mac assigned keys " + keys.map { String($0 + 1) }.joined(separator: ", "))
                }
                if !playableAssignment {
                    Text("Choose a compatible mode in the assigned family, or disconnect and pair again.")
                }
            }
            if !connectionStatus.isEmpty { Text(connectionStatus).font(.caption) }
        }
    }

    /// A permission dialog can deactivate the scene. It must never implicitly arm a camera or socket.
    private func cameraPermissionForPairing() -> Bool {
        if MobileAirSensorSource.authorization == .authorized { return true }
        guard MobileAirSensorSource.authorization == .notDetermined else {
            connectionStatus = "Allow camera access in Settings to use the Air instrument."
            return false
        }
        guard !askingPermission else { return false }
        askingPermission = true
        Task { @MainActor in
            let granted = await MobileAirSensorSource.requestCameraPermission()
            askingPermission = false
            connectionStatus = granted ? "Camera permission granted. Continue when ready." : "Camera permission denied."
        }
        return false
    }

    private func connect() {
        guard useMac, !configurationLocked, valid, scenePhase == .active,
              let endpoint = MobileLANEndpoint(pageAddress: pageAddress),
              MobileLANEndpoint.invitationBytes(invitation) != nil,
              cameraPermissionForPairing() else { return }
        let client = MobileLANSocket(endpoint: endpoint, selection: mode.isHelper ? .helper(helperIndex) : .keys)
        let secret = invitation
        invitation = ""
        guard client.connect(invitation: secret) else {
            client.stop()
            connectionStatus = "Connection setup failed."
            return
        }
        socket = client
        assignment = nil
        connectionStatus = "Connecting to the Mac"
    }

    private func openTouchPiano(){
        guard !busy,useMac,scenePhase == .active,let socket,
              let mask=socket.status().assignment?.piano,mask != 0 else{return}
        liveTouchMask=mask;liveTouchID=UUID()
        status="Assigned touch piano · press Arm to play"
    }
    private func start() {
        guard !busy, !scanning, !askingPermission, valid, playableAssignment, scenePhase == .active else {return}
        let ticket=UUID();generation=ticket;pending=true;status="Waiting for camera permission"
        Task { @MainActor in
            let granted=await MobileAirSensorSource.requestCameraPermission()
            guard generation==ticket,pending else {return}
            guard granted,scenePhase == .active else {stop("Camera permission denied or app inactive");return}
            let keys: Int
            if useMac {
                guard let assigned = socket?.status().assignment else { stop("Mac assignment ended"); return }
                keys = assigned.piano
            } else { keys = (1 << 25) - 1 }
            guard let next=MobileAirCaptureProjection(mode:mode,keys:keys,role:role,
                orientation:musicalOrientation,mirrorX:mirror,near:near,far:far) else {stop("Invalid setup");return}
            let capture=MobileAirSensorSource()
            projection=next;source=capture;pending=false;status="Starting sensors"
            capture.start(backend:backend,orientation:sensorOrientation,cameraID:backend == .lidar ? nil:cameraID,zoom:backend == .lidar ? 1:zoom)
        }
    }
    private func pauseInstrument() {
        guard let socket,assignment != nil else {return}
        generation=UUID();pending=false
        assignment=nil
        socket.pauseForModeChange()
        if let source {source.stop();retiring=source}
        source=nil;projection=nil;output = .init();sample=nil;depth=nil
        status="Waiting for neutral ACK; choose a mode and restart."
    }
    private func stop(_ message:String) {
        generation=UUID();pending=false
        liveTouchID=nil;liveTouchMask=nil
        invitation = ""
        if let socket { socket.stop(); connectionStatus = message }
        socket = nil
        assignment = nil
        if let source {source.stop();retiring=source}
        source=nil;projection=nil
        output = .init();sample=nil;depth=nil;status=message
    }
    private func poll() {
        if retiring?.isStopped == true {retiring=nil}
        if let socket {
            let state = socket.status()
            if state.phase == .closed { stop(state.message); return }
            if assignment != state.assignment { assignment = state.assignment }
            if connectionStatus != state.message { connectionStatus = state.message }
        }
        guard let source,var p=projection else {return}
        let now=MobileAirSensorSource.now
        for event in source.drain() {
            switch event {
            case .ready:status="Sensors started · waiting for hand"
            case .fault(let message):stop(message);return
            case .frame(let frame):
                output=p.receive(frame,now:now)
                if let socket {
                    guard let at = MobileAirCaptureFrame.nanoseconds(frame.time) else { stop("Invalid capture time"); return }
                    socket.offer(output, observedAt: at, stringDeadlines: p.stringDeadlines)
                }
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
