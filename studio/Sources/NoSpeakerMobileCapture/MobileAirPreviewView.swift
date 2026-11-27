#if os(iOS)
import SwiftUI
import Combine
import NoSpeakerCore

/// Local preview and explicitly paired Mac performance share one camera owner.
@MainActor public struct MobileAirPreviewView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var window = MobileCaptureWindow()
    @State private var captureOrientation: MobileSensorOrientation?
    @State private var displayFence = MobileObservationDisplayFence()
    @State private var useMac = false
    @State private var touchOnlyPairing = false
    @State private var pageAddress = ""
    @State private var invitation = ""
    @State private var helperIndex = 0
    @State private var socket: MobileLANSocket?
    @State private var assignment: MobileLANCapabilities.Manifest?
    @State private var connectionStatus = ""
    @State private var scanning = false
    @State private var touchPreview = false
    @State private var xyzStage = false
    @State private var liveTouchID:UUID?
    @State private var liveTouchMask:Int?
    @State private var pairingPermission = MobilePermissionRequestFence()
    private var askingPermission: Bool { pairingPermission.pending }
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
        guard !touchOnlyPairing else { return false }
        guard let assignment, mode.isHelper == (assignment.piano == 0),
              let range = effectiveRange(for: mode) else { return false }
        return MobileAirCaptureProjection(mode: mode, keys: assignment.piano, role: role,
            orientation: musicalOrientation, mirrorX: mirror, near: range.near, far: range.far) != nil
    }
    private var selectedCamera:MobileAirSensorSource.CameraChoice? {cameras.first {$0.id==cameraID}}
    private func refreshCameras() {
        cameras=MobileAirSensorSource.cameras(for:backend)
        cameraID=cameras.first?.id ?? ""
        zoom=selectedCamera?.zoom.defaultFactor ?? 1
    }
    private func effectiveRange(for candidate: MobileAirMode) -> MobileAirEffectiveRange? {
        MobileAirEffectiveRange.resolve(usesDepth: candidate.usesDepth, near: near, far: far)
    }
    private func sensorIssue(for candidate: MobileAirMode) -> String? {
        if candidate.usesDepth && backend != .lidar { return "Requires rear LiDAR" }
        if backend == .lidar && !MobileAirSensorSource.hasLiDAR { return "LiDAR unavailable" }
        if backend != .lidar && selectedCamera?.zoom.contains(zoom) != true { return "Select a supported camera and zoom" }
        if candidate == .chords && role == .single { return "Choose left or right performing hand" }
        if effectiveRange(for: candidate) == nil {
            return "Set valid depth bounds at least 0.10 m apart. If an exact 0.10 m gap is rejected, increase it by one slider step."
        }
        return nil
    }
    private func assignmentIssue(for candidate: MobileAirMode) -> String? {
        guard useMac else { return nil }
        if touchOnlyPairing { return "Touch-only session; disconnect and pair for Air" }
        guard let assignment else { return "Connect and wait for the Mac assignment" }
        if candidate.isHelper != (assignment.piano == 0) { return "Different assigned family; disconnect and pair again" }
        if candidate == .strings && assignment.piano.nonzeroBitCount < 3 { return "Requires at least three assigned keys" }
        if candidate == .chords && !MobileAirInstrument.chordOffsets.contains(where: { notes in
            notes.allSatisfy { assignment.piano & (1 << $0) != 0 }
        }) { return "Requires an assigned complete chord shape" }
        return nil
    }
    private var valid: Bool { sensorIssue(for: mode) == nil }
    // Source eligibility is not a negotiated host capability. Never convert here.
    private var responseGuide: String {
        switch mode {
        case .horizontal, .vertical, .aperture, .depthControl:
            return "Position source · Relative is a proposed host response; not negotiated on mobile."
        case .speed:
            return "Speed source · keep absolute until a separate relative-speed contract is reviewed."
        case .pinchHelper, .toggleHelper:
            return "Binary gate · use Absolute response on the Mac. The current assignment does not report its response mode."
        case .pinchKeys, .chords, .strings, .depthKeys:
            return "Discrete notes · no relative displacement."
        }
    }
    private var modeGuide: String {
        switch mode {
        case .pinchKeys: return "Move horizontally to choose a logical key; open then pinch to hold it. Open to release."
        case .chords: return "Use the other hand to select a chord; open then pinch with the performing hand. Losing either hand releases."
        case .strings: return "Cross the three vertical string regions; notes are short pulses, not sustained holds."
        case .horizontal: return "Horizontal hand position controls the assigned helper."
        case .vertical: return "Vertical hand position controls the assigned helper."
        case .aperture: return "Thumb-to-index aperture controls the assigned helper."
        case .speed: return "Hand motion speed controls the assigned helper."
        case .pinchHelper: return "Open then pinch to engage; open to disengage."
        case .toggleHelper: return "Open then pinch to toggle; tracking loss clears the latch."
        case .depthKeys: return "Move within the calibrated near/far range to choose a depth zone."
        case .depthControl: return "Near/far distance controls the assigned helper; invalid depth releases."
        }
    }

    private var logicalSlots: [Int] {
        let mask = useMac ? (assignment?.piano ?? 0) : (1 << 25) - 1
        return (0..<25).filter { mask & (1 << $0) != 0 }
    }
    // Guides are in the same oriented control coordinates as the hand marker.
    // They are explanatory regions, never a receiver or tracking confirmation.
    private func guidePath(in size: CGSize) -> Path {
        Path { p in
            func vertical(_ fraction: CGFloat) {
                p.move(to: CGPoint(x: size.width*fraction, y: 0))
                p.addLine(to: CGPoint(x: size.width*fraction, y: size.height))
            }
            func horizontal(_ fraction: CGFloat) {
                p.move(to: CGPoint(x: 0, y: size.height*fraction))
                p.addLine(to: CGPoint(x: size.width, y: size.height*fraction))
            }
            switch mode {
            case .pinchKeys:
                let count = logicalSlots.count
                if count > 1 { for i in 1..<count { vertical(CGFloat(i)/CGFloat(count)) } }
            case .strings:
                for i in 1...3 { vertical(CGFloat(i)/4) }
            case .horizontal: horizontal(0.5)
            case .vertical: vertical(0.5)
            default: break
            }
        }
    }

    public var body:some View {
        ScrollView {
            VStack(alignment:.leading,spacing:16) {
                Text("TIHULU · Air stage").font(.largeTitle.bold())
                Button("LiDAR XYZ") { xyzStage = true }.disabled(configurationLocked)
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
                } else if useMac,(assignment?.piano ?? 0) != 0 {
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
                        ForEach(MobileAirMode.allCases) { m in
                            let reason = sensorIssue(for: m) ?? (assignment != nil ? assignmentIssue(for: m) : nil)
                            Text(reason.map { m.rawValue + " · " + $0 } ?? m.rawValue).tag(m)
                        }
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
                    if backend == .lidar && mode.usesDepth {
                        VStack(alignment:.leading) {
                            Text("Near: \(near,format:.number.precision(.fractionLength(2))) m")
                            Slider(value:$near,in:0.1...1.5,step:0.05)
                            Text("Far: \(far,format:.number.precision(.fractionLength(2))) m")
                            Slider(value:$far,in:0.2...3,step:0.05)
                        }
                    }
                }.disabled(instrumentLocked || (useMac && touchOnlyPairing))
                if !touchOnlyPairing || !useMac {
                    if let issue = sensorIssue(for: mode) ?? assignmentIssue(for: mode) {
                        Text(issue).foregroundStyle(.orange)
                    }
                    Text(modeGuide).font(.caption).foregroundStyle(.secondary)
                    Text(responseGuide).font(.caption).foregroundStyle(.secondary)
                }
                GeometryReader {geo in
                    ZStack {
                        RoundedRectangle(cornerRadius:16).fill(Color.secondary.opacity(0.12))
                        guidePath(in: geo.size)
                            .stroke(.secondary.opacity(0.5),style:StrokeStyle(lineWidth:1,dash:[5,5]))
                        if let sample {
                            Circle().fill(.cyan).frame(width:22,height:22)
                                .position(x:sample.x*geo.size.width,y:(1-sample.y)*geo.size.height)
                        } else {Text("No fresh observed hand").foregroundStyle(.secondary)}
                    }
                }.frame(height:210).accessibilityLabel("Observed hand position; not tracking admission or receiver feedback")
                if mode == .pinchKeys || mode == .strings {
                    let slots = mode == .strings ? Array(logicalSlots.prefix(3)) : logicalSlots
                    Text("Regions, left to right: " + (slots.isEmpty ? "No assigned keys" : slots.map { String($0 + 1) }.joined(separator: ", ")))
                        .font(.caption)
                }
                if mode == .chords {
                    let available = MobileAirInstrument.chordOffsets.enumerated().filter { _, notes in
                        notes.allSatisfy { logicalSlots.contains($0) }
                    }.map { String($0.offset + 1) }
                    Text("Available chord selectors: " + (available.isEmpty ? "None" : available.joined(separator: ", "))).font(.caption)
                }
                if let depth {
                    Text("Measured palm depth: \(depth,format:.number.precision(.fractionLength(2))) m")
                    if mode.usesDepth, valid, depth.isFinite, (near...far).contains(depth) {
                        ProgressView(value: (far-depth)/(far-near)).accessibilityLabel("Depth within calibrated range")
                        Text("Far → near · measured position, not receiver feedback").font(.caption)
                    } else if mode.usesDepth { Text("Outside calibrated range · released").font(.caption) }
                } else {Text("Depth: unavailable").foregroundStyle(.secondary)}
                if let sample, mode == .aperture || mode == .pinchHelper || mode == .toggleHelper || mode == .pinchKeys {
                    ProgressView(value: sample.aperture).accessibilityLabel("Observed hand aperture")
                }
                if let level=output.level {
                    ProgressView(value:level).accessibilityLabel("Projected helper level")
                    Text("Projected helper: \(Int(level*100))% · not receiver feedback")
                } else {Text("Helper released").foregroundStyle(.secondary)}
                let active=(0..<25).filter { output.keys & (1<<$0) != 0 }
                Text(active.isEmpty ? "All preview keys released":"Logical keys: "+active.map {String($0+1)}.joined(separator:", "))
                ViewThatFits(in: .horizontal) {
                    HStack { stageActions }
                    VStack(alignment: .leading, spacing: 10) { stageActions }
                }
                Text(useMac ? "Your hand position and depth are processed on this device. The Mac receives assigned keys or helper levels." : "Preview keys and helper levels on this device.").font(.caption).foregroundStyle(.secondary)
            }.padding().frame(maxWidth:640).frame(maxWidth:.infinity)
        }
        .background(MobileCaptureSceneProbe(window: window).allowsHitTesting(false))
        .onAppear {if !busy {refreshCameras()}}
        .onChange(of:backend) {_,_ in if !busy {refreshCameras()}}
        .onChange(of:cameraID) {_,_ in if !busy {zoom=selectedCamera?.zoom.defaultFactor ?? 1}}
        .fullScreenCover(isPresented: $xyzStage) {
            MobileDepthXYZStage(returnCapture: { capture in if let capture { retiring = capture } },
                                done: { xyzStage = false })
        }
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
    @ViewBuilder private var stageActions: some View {
        Button(useMac ? "Start playing" : "Start sensors", action: start).buttonStyle(.borderedProminent)
            .disabled(busy || scanning || askingPermission || !valid || !playableAssignment || scenePhase != .active)
        Button("Stop / release") { stop("Stopped") }.buttonStyle(.bordered).disabled(!busy)
        if useMac, socket != nil {
            Button("Pause / change instrument",action:pauseInstrument)
                .buttonStyle(.bordered).disabled(assignment == nil || (source == nil && !pending))
        }
    }
    private var pairingPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Pair for",selection:$touchOnlyPairing) {
                Text("Camera / Air").tag(false)
                Text("Touch piano").tag(true)
            }.pickerStyle(.segmented).disabled(configurationLocked)
            if touchOnlyPairing {
                Text("Manual touch pairing needs no camera access. QR scanning still uses the camera. Reconnect to use Air sensors.").font(.caption)
            }
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
            if !touchOnlyPairing && mode.isHelper {
                Picker("Mac helper lane", selection: $helperIndex) {
                    ForEach(0..<3) { index in Text("Pedal " + String(index + 1)).tag(index) }
                }.disabled(configurationLocked)
            }
            if socket == nil {
                Button("Connect to Mac", action: connect)
                    .disabled(configurationLocked || (!touchOnlyPairing && !valid) || MobileLANEndpoint(pageAddress: pageAddress) == nil ||
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
                if !touchOnlyPairing && !playableAssignment {
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
        guard scenePhase == .active, let ticket = pairingPermission.begin() else { return false }
        Task { @MainActor in
            let granted = await MobileAirSensorSource.requestCameraPermission()
            guard pairingPermission.finish(ticket), scenePhase == .active else { return }
            connectionStatus = granted ? "Camera permission granted. Continue when ready." : "Camera permission denied."
        }
        return false
    }

    private func connect() {
        guard useMac, !configurationLocked, (touchOnlyPairing || valid), scenePhase == .active,
              let endpoint = MobileLANEndpoint(pageAddress: pageAddress),
              MobileLANEndpoint.invitationBytes(invitation) != nil,
              (touchOnlyPairing || cameraPermissionForPairing()) else { return }
        let client = MobileLANSocket(endpoint: endpoint, selection: !touchOnlyPairing && mode.isHelper ? .helper(helperIndex) : .keys)
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
        guard !busy, !scanning, !askingPermission, !(useMac && touchOnlyPairing), valid, playableAssignment, scenePhase == .active,
              let pose = window.orientation else {return}
        captureOrientation = pose
        displayFence = .init()
        let ticket=UUID();generation=ticket;pending=true;status="Waiting for camera permission"
        Task { @MainActor in
            let granted=await MobileAirSensorSource.requestCameraPermission()
            guard generation==ticket,pending else {return}
            guard granted, MobileAirSensorSource.authorization == .authorized, scenePhase == .active,
                  captureOrientation == window.orientation else {
                stop("Camera permission or display orientation changed · restart required"); return
            }
            let keys: Int
            if useMac {
                guard let assigned = socket?.status().assignment else { stop("Mac assignment ended"); return }
                keys = assigned.piano
            } else { keys = (1 << 25) - 1 }
            guard valid, playableAssignment, let range = effectiveRange(for: mode),
                  let next=MobileAirCaptureProjection(mode:mode,keys:keys,role:role,
                orientation:musicalOrientation,mirrorX:mirror,near:range.near,far:range.far) else {stop("Invalid setup");return}
            let capture=MobileAirSensorSource()
            projection=next;source=capture;pending=false;status="Starting sensors"
            capture.start(backend:backend,orientation:sensorOrientation,cameraID:backend == .lidar ? nil:cameraID,zoom:backend == .lidar ? 1:zoom)
        }
    }
    private func pauseInstrument() {
        guard let socket,assignment != nil else {return}
        generation=UUID();pending=false;captureOrientation=nil
        assignment=nil
        socket.pauseForModeChange()
        if let source {source.stop();retiring=source}
        source=nil;projection=nil;output = .init();sample=nil;depth=nil;displayFence = .init()
        status="Waiting for neutral ACK; choose a mode and restart."
    }
    private func stop(_ message:String) {
        pairingPermission.retire()
        generation=UUID();pending=false;captureOrientation=nil
        liveTouchID=nil;liveTouchMask=nil
        invitation = ""
        if let socket { socket.stop(); connectionStatus = message }
        socket = nil
        assignment = nil
        if let source {source.stop();retiring=source}
        source=nil;projection=nil
        output = .init();sample=nil;depth=nil;displayFence = .init();status=message
    }
    private func poll() {
        if retiring?.isStopped == true {retiring=nil}
        if (pending || source != nil),
           scenePhase != .active || captureOrientation == nil || captureOrientation != window.orientation {
            stop("App inactive or display orientation changed · restart required"); return
        }
        if (source != nil || (socket != nil && !touchOnlyPairing)),
           MobileAirSensorSource.authorization != .authorized {
            stop("Camera permission lost"); return
        }
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
                if displayFence.observe(MobileAirCaptureFrame.nanoseconds(frame.time),
                                        now: MobileAirCaptureFrame.nanoseconds(now),
                                        freshness: MobileAirSendGate.freshNS) {
                    sample=observation?.sample?.oriented(musicalOrientation,mirrorX:mirror)
                    depth=sample == nil ? nil : observation?.depth.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
                } else {sample=nil;depth=nil}
            }
        }
        if let release=p.expire(now:now) {output=release}
        if displayFence.expire(now: MobileAirCaptureFrame.nanoseconds(now), freshness: MobileAirSendGate.freshNS) {
            sample=nil;depth=nil
        }
        projection=p
    }
}
#endif
