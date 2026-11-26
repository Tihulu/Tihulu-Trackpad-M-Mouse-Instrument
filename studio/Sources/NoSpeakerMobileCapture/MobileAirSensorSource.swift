#if os(iOS)
import Foundation
@preconcurrency import AVFoundation
@preconcurrency import ARKit
import Vision
import CoreVideo
import ImageIO
import QuartzCore
@preconcurrency import UIKit
import NoSpeakerCore

/// Experimental native sensor source. Single-use instance, serial capture
/// ownership, bounded derived-data mailbox. No MIDI or network side effects.
public final class MobileAirSensorSource: NSObject, @unchecked Sendable,
    AVCaptureVideoDataOutputSampleBufferDelegate, ARSessionDelegate {
    public enum Backend: String, CaseIterable, Identifiable, Sendable {
        case rearCamera, frontCamera, lidar
        public var id: String { rawValue }
    }
    public struct CameraChoice: Identifiable, Equatable, Sendable {
        public let id:String
        public let name:String
        public let zoom:MobileCameraZoomRange
        public let constituentCount:Int
    }
    public static func cameras(for backend:Backend) -> [CameraChoice] {
        devices(for:backend).compactMap { device in
            guard let zoom=MobileCameraZoomRange(minimum:Double(device.minAvailableVideoZoomFactor),maximum:Double(device.maxAvailableVideoZoomFactor),switches:device.virtualDeviceSwitchOverVideoZoomFactors.map(\.doubleValue)) else {return nil}
            return .init(id:device.uniqueID,name:device.localizedName,zoom:zoom,constituentCount:max(1,device.constituentDevices.count))
        }
    }
    private static func devices(for backend:Backend) -> [AVCaptureDevice] {
        guard backend != .lidar else {return []}
        let position:AVCaptureDevice.Position=backend == .frontCamera ? .front : .back
        let types:[AVCaptureDevice.DeviceType]=[.builtInTripleCamera,.builtInDualWideCamera,.builtInDualCamera,.builtInWideAngleCamera,.builtInUltraWideCamera,.builtInTelephotoCamera,.builtInTrueDepthCamera]
        return AVCaptureDevice.DiscoverySession(deviceTypes:types,mediaType:.video,position:position).devices
    }
    public enum Event: Sendable {
        case ready
        case frame(MobileAirCaptureFrame)
        case fault(String)
    }
    public static var hasLiDAR: Bool {
        ARWorldTrackingConfiguration.isSupported &&
        ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth)
    }
    public static var authorization: AVAuthorizationStatus { AVCaptureDevice.authorizationStatus(for:.video) }
    public static func requestCameraPermission() async -> Bool {
        await AVCaptureDevice.requestAccess(for:.video)
    }
    public static var now: Double { CACurrentMediaTime() }

    private let queue=DispatchQueue(label:"com.tihulu.mobile.air.capture",qos:.userInitiated)
    private let lock=NSLock()
    private var events:[Event]=[]
    private var closed=false
    private var started=false
    private var terminal=false
    private var stopped=false
    public var isStopped:Bool {lock.lock();defer{lock.unlock()};return stopped}
    private var camera:AVCaptureSession?
    private var ar:ARSession?
    private var observers:[NSObjectProtocol]=[]
    private let request=VNDetectHumanHandPoseRequest()
    private var lastInference = -Double.infinity
    private var arTrackingLost = false
    private var orientation:MobileSensorOrientation = .up

    public override init() { super.init(); request.maximumHandCount=2 }

    /// Explicit orientation of the raw image for Vision; never infer depth
    /// orientation from display mirroring or the musical coordinate transform.
    public func start(backend:Backend,orientation:MobileSensorOrientation,cameraID:String?=nil,zoom:Double=1) {
        lock.lock()
        let allowed = !started && !closed && !terminal
        if allowed { started=true }
        lock.unlock()
        guard allowed else { return }
        queue.async { [self] in
            guard !isClosed else { return }
            self.orientation=orientation
            guard Self.authorization == .authorized else { fail("Camera permission required."); return }
            observers.append(NotificationCenter.default.addObserver(forName:UIApplication.willResignActiveNotification,object:nil,queue:nil) { [weak self] _ in
                self?.queue.async { [weak self] in self?.fail("App inactive; restart explicitly.") }
            })
            switch backend {
            case .lidar:
                guard cameraID == nil, zoom == 1 else {fail("LiDAR uses its calibrated native camera; zoom unavailable.");return}
                guard Self.hasLiDAR else { fail("LiDAR scene depth is not supported on this device.");return }
                let session=ARSession()
                session.delegateQueue=queue
                session.delegate=self
                let config=ARWorldTrackingConfiguration()
                config.frameSemantics.insert(.sceneDepth)
                ar=session
                session.run(config)
                push(.ready)
            case .frontCamera,.rearCamera:
                do {
                    let choices=Self.devices(for:backend)
                    guard let device=cameraID.flatMap({id in choices.first {$0.uniqueID==id}}) ?? (cameraID == nil ? choices.first : nil) else {fail("Selected camera unavailable.");return}
                    let input=try AVCaptureDeviceInput(device:device)
                    let session=AVCaptureSession()
                    session.beginConfiguration()
                    if session.canSetSessionPreset(.vga640x480) { session.sessionPreset = .vga640x480 }
                    let output=AVCaptureVideoDataOutput()
                    output.alwaysDiscardsLateVideoFrames=true
                    guard session.canAddInput(input), session.canAddOutput(output) else {
                        session.commitConfiguration();fail("Camera configuration unavailable.");return
                    }
                    session.addInput(input); session.addOutput(output)
                    output.setSampleBufferDelegate(self,queue:queue)
                    if let connection=output.connection(with:.video), connection.isVideoMirroringSupported {
                        connection.automaticallyAdjustsVideoMirroring=false
                        connection.isVideoMirrored=false
                    }
                    session.commitConfiguration()
                    camera=session
                    try device.lockForConfiguration()
                    let validZoom=zoom.isFinite && zoom>=Double(device.minAvailableVideoZoomFactor) && zoom<=Double(device.maxAvailableVideoZoomFactor)
                    if validZoom {device.videoZoomFactor=CGFloat(zoom)}
                    device.unlockForConfiguration()
                    guard validZoom else {fail("Zoom not supported by selected camera format.");return}
                    let center=NotificationCenter.default
                    for name in [AVCaptureSession.runtimeErrorNotification,AVCaptureSession.wasInterruptedNotification] {
                        observers.append(center.addObserver(forName:name,object:session,queue:nil) { [weak self] _ in
                            self?.queue.async { [weak self] in self?.fail("Camera interrupted; restart explicitly.") }
                        })
                    }
                    session.startRunning()
                    guard !isClosed else { tearDown();return }
                    guard session.isRunning else { fail("Camera failed to start.");return }
                    push(.ready)
                } catch { fail("Camera configuration failed.") }
            }
        }
    }

    public func stop() {
        lock.lock();closed=true;events.removeAll();lock.unlock()
        queue.async { [self] in tearDown() }
    }
    public func drain() -> [Event] {
        lock.lock();defer {lock.unlock()}
        let batch=events;events.removeAll(keepingCapacity:true);return batch
    }
    private var isClosed:Bool {
        lock.lock();defer{lock.unlock()};return closed||terminal
    }
    private func tearDown() {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
        camera?.stopRunning();camera=nil
        ar?.pause();ar?.delegate=nil;ar=nil
        lock.lock();stopped=true;lock.unlock()
    }
    private func fail(_ message:String) {
        lock.lock()
        if !closed && !terminal { terminal=true;events=[.fault(message)] }
        lock.unlock()
        // Allow capture/delegate callbacks to return before stopping a session.
        queue.async { [self] in tearDown() }
    }
    private func push(_ event:Event) {
        lock.lock()
        guard !closed && !terminal else { lock.unlock();return }
        if events.count>=16 {
            terminal=true;events=[.fault("Sensor backlog; restart explicitly.")];lock.unlock()
            queue.async { [self] in tearDown() };return
        }
        events.append(event);lock.unlock()
    }

    private var exif:CGImagePropertyOrientation {
        switch orientation { case .up:.up;case .right:.right;case .down:.down;case .left:.left }
    }
    public func captureOutput(_ output:AVCaptureOutput,didOutput sampleBuffer:CMSampleBuffer,from connection:AVCaptureConnection) {
        guard let image=CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        // AVFoundation capture presentation time is in the host-clock domain.
        infer(image:image,depth:nil,time:CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds)
    }
    public func session(_ session:ARSession,didUpdate frame:ARFrame) {
        guard session === ar,!isClosed else { return }
        // Publish the first loss edge immediately; subsequent empty frames
        // remain bounded. A later normal frame must reacquire both gates.
        if case .normal=frame.camera.trackingState {
            arTrackingLost=false
            infer(image:frame.capturedImage,depth:frame.sceneDepth,time:frame.timestamp)
        } else {
            let now=Self.now
            guard !arTrackingLost || now-lastInference>=1.0/15 else {return}
            arTrackingLost=true;lastInference=now
            push(.frame(.init(time:frame.timestamp)))
        }
    }
    public func session(_ session:ARSession,didFailWithError error:Error) { fail("AR session failed; restart explicitly.") }
    public func sessionWasInterrupted(_ session:ARSession) { fail("AR session interrupted; restart explicitly.") }
    public func sessionInterruptionEnded(_ session:ARSession) { /* explicit restart only */ }

    private func infer(image:CVPixelBuffer,depth:ARDepthData?,time:Double) {
        guard !isClosed else { return }
        let now=Self.now
        guard now-lastInference>=1.0/15 else { return }
        lastInference=now
        guard time.isFinite,time>=0,now>=time,now-time<0.15 else {
            push(.frame(.init(time:now)));return
        }
        do {
            try VNImageRequestHandler(cvPixelBuffer:image,orientation:exif,options:[:]).perform([request])
            let hands=request.results ?? []
            let left=hands.filter { $0.chirality == .left }
            let right=hands.filter { $0.chirality == .right }
            let l=left.count==1 ? observation(left[0],depth:depth) : nil
            let r=right.count==1 ? observation(right[0],depth:depth) : nil
            let single: MobileAirObservation?
            if hands.count == 1 {
                switch hands[0].chirality {
                case .left: single = l
                case .right: single = r
                default: single = observation(hands[0], depth: depth)
                }
            } else { single = nil }
            guard Self.now-time<0.15 else { push(.frame(.init(time:time)));return }
            push(.frame(.init(single:single,left:l,right:r,time:time)))
        } catch { push(.frame(.init(time:time))) }
    }
    private func observation(_ pose:VNHumanHandPoseObservation,depth:ARDepthData?) -> MobileAirObservation? {
        guard let points=try? pose.recognizedPoints(.all) else { return nil }
        func point(_ name:VNHumanHandPoseObservation.JointName) -> AirHandPoint? {
            guard let p=points[name] else { return nil }
            return .init(x:Double(p.location.x),y:Double(p.location.y),confidence:Double(p.confidence))
        }
        guard let thumb=point(.thumbTip),let index=point(.indexTip),let wrist=point(.wrist),
              let middle=point(.middleMCP),let sample=AirHandSample(thumb:thumb,index:index,wrist:wrist,middleBase:middle) else { return nil }
        let chains:[(VNHumanHandPoseObservation.JointName,VNHumanHandPoseObservation.JointName,VNHumanHandPoseObservation.JointName)]=[
            (.thumbCMC,.thumbMP,.thumbTip),(.indexMCP,.indexPIP,.indexTip),(.middleMCP,.middlePIP,.middleTip),(.ringMCP,.ringPIP,.ringTip),(.littleMCP,.littlePIP,.littleTip)]
        let fingers=chains.compactMap { a,b,c -> AirFingerChain? in
            guard let a=point(a),let b=point(b),let c=point(c) else { return nil }
            return .init(base:a,joint:b,tip:c)
        }
        let confidence=fingers.flatMap { [$0.base.confidence,$0.joint.confidence,$0.tip.confidence] }.min() ?? 0
        let palmX=(wrist.x+middle.x)/2,palmY=(wrist.y+middle.y)/2
        let measured=depth.flatMap { palmDepth($0,x:palmX,y:palmY) }
        let palm = measured.map {
            DepthXYZPoint(x: palmX, y: palmY, meters: $0, confidence: min(wrist.confidence, middle.confidence))
        }
        return .init(sample:sample, fingers:AirFingerCount.classify(fingers), confidence:confidence,
                     depth:measured, measuredPalm:palm)
    }
    private func palmDepth(_ depth:ARDepthData,x:Double,y:Double) -> Double? {
        guard let p=orientation.depthPoint(x:x,y:y),let confidence=depth.confidenceMap else {return nil}
        let map=depth.depthMap,w=CVPixelBufferGetWidth(map),h=CVPixelBufferGetHeight(map)
        guard w>=3,h>=3,CVPixelBufferGetWidth(confidence)==w,CVPixelBufferGetHeight(confidence)==h,
              CVPixelBufferGetPixelFormatType(map)==kCVPixelFormatType_DepthFloat32,
              CVPixelBufferGetPixelFormatType(confidence)==kCVPixelFormatType_OneComponent8,
              CVPixelBufferGetBytesPerRow(map)>=w*MemoryLayout<Float>.stride,
              CVPixelBufferGetBytesPerRow(confidence)>=w,
              CVPixelBufferLockBaseAddress(map,.readOnly)==kCVReturnSuccess else {return nil}
        defer {CVPixelBufferUnlockBaseAddress(map,.readOnly)}
        guard CVPixelBufferLockBaseAddress(confidence,.readOnly)==kCVReturnSuccess else {return nil}
        defer {CVPixelBufferUnlockBaseAddress(confidence,.readOnly)}
        guard let d=CVPixelBufferGetBaseAddress(map),let c=CVPixelBufferGetBaseAddress(confidence) else {return nil}
        let ix=Int((p.x*Double(w-1)).rounded()),iy=Int((p.y*Double(h-1)).rounded())
        guard ix>0,ix<w-1,iy>0,iy<h-1 else {return nil}
        let dr=CVPixelBufferGetBytesPerRow(map),cr=CVPixelBufferGetBytesPerRow(confidence)
        var samples:[(meters:Float,confidence:UInt8)]=[]
        for row in (iy-1)...(iy+1) {
            for col in (ix-1)...(ix+1) {
                samples.append((d.loadUnaligned(fromByteOffset:row*dr+col*4,as:Float.self),
                                c.load(fromByteOffset:row*cr+col,as:UInt8.self)))
            }
        }
        return MobileSensorOrientation.palmDepth(samples)
    }
}
#endif
