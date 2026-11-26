#if os(iOS)
import Combine
import SwiftUI
import UIKit
import NoSpeakerCore

/// Use the scene actually displaying this stage, including iPad multiwindow.
@MainActor private final class XYZWindow {
    weak var view: UIView?
    var orientation: MobileSensorOrientation? {
        switch view?.window?.windowScene?.interfaceOrientation {
        case .portrait: return .right
        case .portraitUpsideDown: return .left
        case .landscapeRight: return .up
        case .landscapeLeft: return .down
        default: return nil
        }
    }
}

private struct XYZSceneProbe: UIViewRepresentable {
    let window: XYZWindow
    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        window.view = view
        return view
    }
    func updateUIView(_ uiView: UIView, context: Context) {}
}

@MainActor struct MobileDepthXYZStage: View {
    @Environment(\.scenePhase) private var scene
    @AppStorage("mobile.depthXYZ.calibrations.v1") private var stored = Data()
    @State private var window = XYZWindow()
    @State private var volume = DepthXYZVolume()
    @State private var axes = 7
    private enum Role: String, CaseIterable { case helper = "Helper", instrument = "Instrument", hybrid = "Hybrid" }
    @State private var role = Role.helper
    private var instrument: Bool { role != .helper }
    private var usesControls: Bool { role != .instrument }
    @State private var pitchAxis = DepthXYZPitchAxis.z
    @State private var keyboard: DepthXYZKeys?
    @State private var activeKey: Int?
    @State private var name = ""
    @State private var paired = false
    @State private var address = ""
    @State private var invitation = ""
    @State private var sensor: MobileAirSensorSource?
    @State private var retiring: MobileAirSensorSource?
    @State private var socket: MobileLANSocket?
    @State private var orientation: MobileSensorOrientation?
    @State private var tracking: DepthXYZTracking?
    @State private var levels: DepthXYZLevels?
    @State private var palm: DepthXYZPoint?
    @State private var status = "Stopped"
    @State private var requesting = false
    @State private var ready = false
    private let tick = Timer.publish(every: 0.035, on: .main, in: .common).autoconnect()
    let returnCapture: (MobileAirSensorSource?) -> Void
    let done: () -> Void

    private var locked: Bool { sensor != nil || retiring != nil || socket != nil || requesting }
    private var library: DepthXYZCalibrationProfiles? {
        if stored.isEmpty { return .init() }
        return try? JSONDecoder().decode(DepthXYZCalibrationProfiles.self, from: stored)
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("LiDAR XYZ").font(.title.bold())
                    Spacer()
                    Button("Done") { stop("Stopped"); done() }
                }
                Text(status).accessibilityLabel("Sensor and connection status: " + status)
                if sensor != nil {
                    performance
                } else {
                    if !MobileAirSensorSource.hasLiDAR {
                        Text("This device has no supported rear scene depth. Camera and touch controls are available from Air stage.")
                    }
                    setup
                }
                HStack {
                    if sensor == nil {
                        Button("Start", action: start)
                            .disabled(scene != .active || !MobileAirSensorSource.hasLiDAR || !volume.isValid ||
                                      (usesControls && axes == 0) || retiring != nil || requesting || (paired && !ready))
                    }
                    Button("Stop") { stop("Stopped · outputs released") }.disabled(!locked)
                    Button("Panic", role: .destructive) { stop("Panic · this device disconnected") }.disabled(!locked)
                }.buttonStyle(.bordered)
            }.padding().frame(maxWidth: 760).frame(maxWidth: .infinity)
        }
        .background(XYZSceneProbe(window: window).allowsHitTesting(false))
        .onReceive(tick) { _ in poll() }
        .onChange(of: scene) { _, phase in if phase != .active { stop("App inactive · restart required") } }
        .onDisappear { stop("Closed"); returnCapture(retiring) }
    }

    private var performance: some View {
        VStack(alignment: .leading, spacing: 10) {
            GeometryReader { area in
                ZStack {
                    RoundedRectangle(cornerRadius: 12).fill(.secondary.opacity(0.12))
                    if let levels {
                        Circle().fill(.cyan).frame(width: 22,height: 22)
                            .position(x: levels.x * area.size.width, y: (1-levels.y) * area.size.height)
                    } else { Text("Waiting for a reliable palm inside the volume") }
                }
            }.frame(minHeight: 150, idealHeight: 240).accessibilityHidden(true)
            if let levels, let palm {
                ProgressView(value: levels.z) { Text(String(format: "Depth %.2f m", palm.meters)) }
                Text(String(format: "X %.0f%%   Y %.0f%%   Z %.0f%%", levels.x*100, levels.y*100, levels.z*100))
                Text(String(format: "Palm landmark confidence %.0f%%", palm.confidence*100)).font(.caption)
            }
            Text(axesDescription).font(.caption)
            if instrument { Text(activeKey.map { "Logical key " + String($0 + 1) } ?? "No active key") }
        }
    }
    private var axesDescription: String {
        var assignments = [String]()
        if instrument { assignments.append(pitchAxis.rawValue.uppercased() + (paired ? " → Mac-assigned keys" : " → preview keys")) }
        if usesControls { assignments += ["X", "Y", "Z"].enumerated().compactMap { index, axis in
            axes & (1 << index) == 0 ? nil : "\(axis) → Mac control \(index + 1)"
        } }
        return assignments.joined(separator: " · ")
    }
    private var setup: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Move one palm right for X, up for Y, and away from the rear camera for Z.")
            Picker("Role", selection: $role) {
                ForEach(Role.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.segmented).disabled(locked)
            if instrument {
                Picker("Pitch axis", selection: $pitchAxis) {
                    ForEach(DepthXYZPitchAxis.allCases) { Text($0.rawValue.uppercased()).tag($0) }
                }.disabled(locked)
            }
            if usesControls { HStack {
                ForEach(0..<3) { i in
                    Toggle(["X", "Y", "Z"][i], isOn: Binding(
                        get: { axes & (1 << i) != 0 },
                        set: { on in if on { axes |= 1 << i } else { axes &= ~(1 << i) } }))
                }
            }.disabled(locked) }
            DisclosureGroup("Playing volume and profiles") {
                bound("Left", $volume.left, 0...1)
                bound("Right", $volume.right, 0...1)
                bound("Bottom", $volume.bottom, 0...1)
                bound("Top", $volume.top, 0...1)
                bound("Near (m)", $volume.nearMeters, 0.1...3)
                bound("Far (m)", $volume.farMeters, 0.1...3)
                TextField("Calibration name", text: $name).textFieldStyle(.roundedBorder)
                Button("Save new calibration") { save() }
                    .disabled(!volume.isValid || (usesControls && axes == 0) || name.isEmpty || library == nil)
                if let library {
                    ForEach(library.profiles) { profile in
                        Button(profile.name) {
                            volume = profile.volume; axes = profile.axisMask; name = profile.name
                            role = profile.hybrid == true ? .hybrid : profile.pitchAxis == nil ? .helper : .instrument
                            pitchAxis = profile.pitchAxis ?? .z
                            status = "Loaded " + profile.name
                        }
                    }
                } else { Text("Saved calibration data could not be read.") }
            }.disabled(locked)
            if !volume.isValid || (usesControls && axes == 0) { Text("Enable an axis and set ordered bounds with sufficient spacing.") }
            Toggle("Send to paired Mac", isOn: $paired).disabled(locked)
            if paired {
                Text(axesDescription)
                Text("Set MIDI targets and channels in the selected group’s mobile mapping on the Mac.").font(.caption)
                TextField("Mac controller address", text: $address).textInputAutocapitalization(.never)
                    .autocorrectionDisabled().keyboardType(.URL).disabled(locked)
                SecureField("One-time invitation", text: $invitation).privacySensitive().disabled(locked)
                Button("Connect", action: connect).disabled(locked || scene != .active || (usesControls && axes == 0) ||
                    MobileLANEndpoint(pageAddress: address) == nil || MobileLANEndpoint.invitationBytes(invitation) == nil)
            }
        }
    }
    private func bound(_ title: String, _ value: Binding<Double>, _ range: ClosedRange<Double>) -> some View {
        Stepper(String(format: "%@  %.2f", title, value.wrappedValue), value: value, in: range, step: 0.05)
    }
    private func save() {
        guard var library else { return }
        do {
            try library.save(name: name, volume: volume, axisMask: usesControls ? axes : 7, pitchAxis: instrument ? pitchAxis : nil, hybrid: role == .hybrid)
            stored = try JSONEncoder().encode(library)
            status = "Calibration saved"
        } catch { status = "Choose a unique calibration name and valid volume (up to 32 profiles)." }
    }
    private func connect() {
        guard !locked, scene == .active, (!usesControls || (1...7).contains(axes)),
              let endpoint = MobileLANEndpoint(pageAddress: address) else { return }
        let selection: MobileLANSession.Selection
        switch role {
        case .instrument: selection = .keys
        case .helper: selection = .xyz(mask: axes)
        case .hybrid: selection = .hybrid(mask: axes)
        }
        let client = MobileLANSocket(endpoint: endpoint, selection: selection)
        let token = invitation
        invitation = ""
        guard client.connect(invitation: token) else { client.stop(); status = "Pairing failed"; return }
        socket = client; status = "Pairing"
    }
    private func start() {
        guard sensor == nil, retiring == nil, !requesting, scene == .active, MobileAirSensorSource.hasLiDAR,
              let pose = window.orientation, let tracker = DepthXYZTracking(volume: volume),
              (!usesControls || (1...7).contains(axes)), !paired || assigned(socket?.status().assignment) else { return }
        guard MobileAirSensorSource.authorization == .authorized else {
            if MobileAirSensorSource.authorization == .notDetermined {
                requesting = true
                Task { @MainActor in
                    let granted = await MobileAirSensorSource.requestCameraPermission()
                    requesting = false
                    status = granted ? "Camera permission granted · press Start" : "Camera permission denied"
                }
            } else { status = "Camera access unavailable · check Settings" }
            return
        }
        if instrument {
            let mask = paired ? socket?.status().assignment?.piano ?? 0 : (1 << 25) - 1
            guard let keys = DepthXYZKeys(authorized: mask, axis: pitchAxis) else { return }
            keyboard = keys
        }
        orientation = pose; tracking = tracker
        let capture = MobileAirSensorSource()
        sensor = capture
        capture.start(backend: .lidar, orientation: pose)
        status = "Waiting for measured palm"
    }
    private func assigned(_ manifest: MobileLANCapabilities.Manifest?) -> Bool {
        switch role {
        case .helper: return manifest?.xyzLane(mask: axes) != nil
        case .instrument: return manifest?.keysLane() != nil
        case .hybrid: return manifest?.hybridLane(mask: axes) != nil
        }
    }
    private func stop(_ reason: String) {
        socket?.stop(); socket = nil; ready = false; invitation = ""
        if let sensor { sensor.stop(); retiring = sensor }
        sensor = nil; tracking = nil; keyboard = nil; activeKey = nil; levels = nil; palm = nil; orientation = nil; status = reason
    }
    private func poll() {
        if retiring?.isStopped == true { retiring = nil }
        if let socket {
            let state = socket.status()
            if state.phase == .closed { stop(state.message); return }
            ready = assigned(state.assignment)
            if sensor == nil { status = state.message }
        }
        guard let sensor, var tracker = tracking else { return }
        guard scene == .active, MobileAirSensorSource.authorization == .authorized,
              orientation == window.orientation else { stop("Sensor permission or orientation changed · restart required"); return }
        for event in sensor.drain() {
            switch event {
            case .fault(let message): stop(message); return
            case .ready: break
            case .frame(let frame):
                let point = frame.single?.measuredPalm
                levels = tracker.observe(point, at: frame.time, now: MobileAirSensorSource.now)
                palm = levels == nil ? nil : point
                status = levels == nil ? "Tracking lost or acquiring · controls released" : "Tracking"
                let keyOutput = keyboard?.output(levels)
                activeKey = keyOutput.flatMap { $0.keys == 0 ? nil : $0.keys.trailingZeroBitCount }
                if let socket {
                    guard let time = MobileAirCaptureFrame.nanoseconds(frame.time) else { stop("Invalid capture time"); return }
                    var output = keyOutput ?? MobileAirOutput()
                    if usesControls, let levels {
                        output.xyz = [levels.x,levels.y,levels.z].enumerated().map { i, value in
                            axes & (1 << i) == 0 ? nil : value
                        }
                    }
                    socket.offer(output, observedAt: time)
                }
            }
        }
        if tracker.expire(now: MobileAirSensorSource.now) {
            _ = keyboard?.output(nil); activeKey = nil
            levels = nil; palm = nil; status = "Sensor frames expired · controls released"
        }
        tracking = tracker
    }
}
#endif
