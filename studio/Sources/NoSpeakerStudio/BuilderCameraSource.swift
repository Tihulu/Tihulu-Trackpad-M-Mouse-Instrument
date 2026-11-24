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

    func start(deviceID: String) {
        queue.async { [self] in
            guard !isClosed else { return }
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
        } catch { push(.frame(nil, now)) }
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
