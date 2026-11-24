#if os(macOS)
import Foundation
@preconcurrency import AVFoundation
import Vision
import NoSpeakerCore

/// One serial queue owns capture and Vision. No image is retained, recorded,
/// transmitted or delivered to the main actor. Only derived samples leave it.
/// The mailbox preserves lost-hand edges; overflow is an explicit fault.
final class BuilderCameraSource: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    enum Event: Sendable {
        case ready
        case frame(AirHandSample?, Double)
        case dualFrame(Int?, Double, AirHandSample?, Double)
        case helperFrame(AirHandSample?, AirHandSample?, Double)
        case combinedFrame(Int?, Double, AirHandSample?, AirHandSample?, Double)
        case fault(String)
    }
    private let queue = DispatchQueue(label: "com.tihulu.builder.camera", qos: .userInitiated)
    private let lock = NSLock()
    private var events: [Event] = []
    private var closed = false
    private var overflow = false
    private var stopped = false
    // Queue confined:
    private var capture: AVCaptureSession?
    private let request = VNDetectHumanHandPoseRequest()
    private var lastFrame = -1.0
    private var dualMode = false
    private var helperMode = false
    private var swapRoles = false
    private var observers: [NSObjectProtocol] = []

    static var authorization: AVAuthorizationStatus { AVCaptureDevice.authorizationStatus(for: .video) }

    struct Choice: Identifiable, Equatable, Sendable {
        let id: String
        let name: String
    }

    static func choices() -> [Choice] {
        AVCaptureDevice.devices(for: .video).map { .init(id: $0.uniqueID, name: $0.localizedName) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func start(deviceID: String, dualMode: Bool = false, swapRoles: Bool = false, helperMode: Bool = false) {
        queue.async { [self] in
            guard !isClosed else { return }
            self.dualMode = dualMode
            self.helperMode = helperMode
            self.swapRoles = swapRoles
            do {
                guard Self.authorization == .authorized else { throw CameraError.permission }
                let device = deviceID.isEmpty ? AVCaptureDevice.default(for: .video) :
                    AVCaptureDevice.devices(for: .video).first { $0.uniqueID == deviceID }
                guard let device else { throw CameraError.unavailable }
                let session = AVCaptureSession()
                session.beginConfiguration()
                if session.canSetSessionPreset(.vga640x480) { session.sessionPreset = .vga640x480 }
                let input = try AVCaptureDeviceInput(device: device)
                guard session.canAddInput(input) else { throw CameraError.configuration }
                session.addInput(input)
                let output = AVCaptureVideoDataOutput()
                output.alwaysDiscardsLateVideoFrames = true
                output.setSampleBufferDelegate(self, queue: queue)
                guard session.canAddOutput(output) else { throw CameraError.configuration }
                session.addOutput(output)
                session.commitConfiguration()
                request.maximumHandCount = 2
                guard !isClosed else { return }
                capture = session
                let center = NotificationCenter.default
                observers.append(center.addObserver(forName: AVCaptureSession.runtimeErrorNotification, object: session, queue: nil) { [weak self] _ in
                    self?.push(.fault("Camera runtime error. Restart explicitly."))
                })
                observers.append(center.addObserver(forName: AVCaptureDevice.wasDisconnectedNotification, object: device, queue: nil) { [weak self] _ in
                    self?.push(.fault("Selected camera disconnected. Restart explicitly."))
                })
                session.startRunning()
                guard !isClosed else { tearDown(); return }
                guard session.isRunning else { throw CameraError.configuration }
                push(.ready)
            } catch {
                tearDown()
                push(.fault(error.localizedDescription))
            }
        }
    }

    func stop() {
        lock.lock()
        closed = true
        events.removeAll()
        lock.unlock()
        queue.async { [self] in
            tearDown()
            lock.lock()
            stopped = true
            lock.unlock()
        }
    }

    private func tearDown() {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
        capture?.stopRunning()
        capture = nil
    }

    var isStopped: Bool {
        lock.lock(); defer { lock.unlock() }
        return stopped
    }

    private var isClosed: Bool {
        lock.lock(); defer { lock.unlock() }
        return closed
    }

    private func push(_ event: Event) {
        lock.lock(); defer { lock.unlock() }
        guard !closed, !overflow else { return }
        guard events.count < 16 else {
            overflow = true
            events = [.fault("Camera control backlog. Restart explicitly.")]
            return
        }
        events.append(event)
    }

    func drain() -> [Event] {
        lock.lock(); defer { lock.unlock() }
        let batch = events
        events.removeAll(keepingCapacity: true)
        return batch
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard !isClosed else { return }
        let now = ProcessInfo.processInfo.systemUptime
        // At most 15 Vision requests/sec, with no queued inference tasks.
        guard now - lastFrame >= 1.0 / 15.0 else { return }
        lastFrame = now
        do {
            try VNImageRequestHandler(cmSampleBuffer: sampleBuffer, orientation: .up, options: [:]).perform([request])
            if helperMode {
                let hands = request.results ?? []
                func sample(_ hand: VNHumanHandPoseObservation) -> AirHandSample? {
                    guard let points = try? hand.recognizedPoints(.all) else { return nil }
                    func point(_ name:VNHumanHandPoseObservation.JointName) -> AirHandPoint? {
                        guard let p = points[name] else { return nil }
                        return .init(x:Double(p.location.x),y:Double(p.location.y),confidence:Double(p.confidence))
                    }
                    guard let thumb = point(.thumbTip), let index = point(.indexTip),
                          let wrist = point(.wrist), let middle = point(.middleMCP) else { return nil }
                    return AirHandSample(thumb:thumb,index:index,wrist:wrist,middleBase:middle)
                }
                let left = hands.filter { $0.chirality == .left }
                let right = hands.filter { $0.chirality == .right }
                let l = left.count == 1 ? sample(left[0]) : nil
                let r = right.count == 1 ? sample(right[0]) : nil
                if dualMode {
                    let chord = swapRoles ? right : left
                    let pose = chord.count == 1 ? chord[0] : nil
                    let points = try? pose?.recognizedPoints(.all)
                    let chains: [(VNHumanHandPoseObservation.JointName,VNHumanHandPoseObservation.JointName,VNHumanHandPoseObservation.JointName)] = [
                        (.thumbCMC,.thumbMP,.thumbTip),(.indexMCP,.indexPIP,.indexTip),
                        (.middleMCP,.middlePIP,.middleTip),(.ringMCP,.ringPIP,.ringTip),(.littleMCP,.littlePIP,.littleTip)]
                    func point(_ name:VNHumanHandPoseObservation.JointName) -> AirHandPoint? {
                        guard let p = points?[name] else { return nil }
                        return .init(x:Double(p.location.x),y:Double(p.location.y),confidence:Double(p.confidence))
                    }
                    let fingers = chains.compactMap { chain -> AirFingerChain? in
                        guard let a = point(chain.0),let b = point(chain.1),let c = point(chain.2) else { return nil }
                        return .init(base:a,joint:b,tip:c)
                    }
                    let confidence = fingers.flatMap { [$0.base.confidence,$0.joint.confidence,$0.tip.confidence] }.min() ?? 0
                    push(.combinedFrame(AirFingerCount.classify(fingers),confidence,l,r,now))
                } else { push(.helperFrame(l,r,now)) }
                return
            }
            if dualMode {
                guard let hands = request.results, hands.count == 2,
                      let left = hands.first(where: { $0.chirality == .left }),
                      let right = hands.first(where: { $0.chirality == .right }) else {
                    push(.dualFrame(nil, 0, nil, now)); return
                }
                let chord = swapRoles ? right : left
                let helper = swapRoles ? left : right
                let points = try chord.recognizedPoints(.all)
                let chains: [(VNHumanHandPoseObservation.JointName, VNHumanHandPoseObservation.JointName, VNHumanHandPoseObservation.JointName)] = [
                    (.thumbCMC, .thumbMP, .thumbTip), (.indexMCP, .indexPIP, .indexTip),
                    (.middleMCP, .middlePIP, .middleTip), (.ringMCP, .ringPIP, .ringTip),
                    (.littleMCP, .littlePIP, .littleTip)]
                func convert(_ p: VNRecognizedPoint) -> AirHandPoint {
                    .init(x: Double(p.location.x), y: Double(p.location.y), confidence: Double(p.confidence))
                }
                let fingers = chains.compactMap { chain -> AirFingerChain? in
                    guard let a = points[chain.0], let b = points[chain.1], let c = points[chain.2] else { return nil }
                    return .init(base: convert(a), joint: convert(b), tip: convert(c))
                }
                let confidence = fingers.flatMap { [$0.base.confidence, $0.joint.confidence, $0.tip.confidence] }.min() ?? 0
                let hp = try helper.recognizedPoints(.all)
                guard let thumb = hp[.thumbTip], let index = hp[.indexTip],
                      let wrist = hp[.wrist], let middle = hp[.middleMCP] else {
                    push(.dualFrame(nil, 0, nil, now)); return
                }
                let sample = AirHandSample(thumb: convert(thumb), index: convert(index), wrist: convert(wrist), middleBase: convert(middle))
                push(.dualFrame(AirFingerCount.classify(fingers), confidence, sample, now))
                return
            }
            guard let hands = request.results, hands.count == 1, let hand = hands.first else {
                push(.frame(nil, now)); return
            }
            let points = try hand.recognizedPoints(.all)
            func point(_ name: VNHumanHandPoseObservation.JointName) -> AirHandPoint? {
                guard let p = points[name] else { return nil }
                return .init(x: Double(p.location.x), y: Double(p.location.y), confidence: Double(p.confidence))
            }
            guard let thumb = point(.thumbTip), let index = point(.indexTip),
                  let wrist = point(.wrist), let middle = point(.middleMCP) else {
                push(.frame(nil, now)); return
            }
            push(.frame(AirHandSample(thumb: thumb, index: index, wrist: wrist, middleBase: middle), now))
        } catch {
            if helperMode && dualMode { push(.combinedFrame(nil,0,nil,nil,now)) }
            else if helperMode { push(.helperFrame(nil,nil,now)) }
            else if dualMode { push(.dualFrame(nil, 0, nil, now)) }
            else { push(.frame(nil, now)) }
        }
    }

    private enum CameraError: LocalizedError {
        case permission, unavailable, configuration
        var errorDescription: String? {
            switch self {
            case .permission: "Camera permission is not granted."
            case .unavailable: "Selected video camera is unavailable. Refresh the camera list."
            case .configuration: "Could not start the camera."
            }
        }
    }
}
#endif
