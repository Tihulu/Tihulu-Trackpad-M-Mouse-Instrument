#if os(macOS)
import Foundation
import ScreenCaptureKit
import CoreMedia
import CoreGraphics
import AudioToolbox
import NoSpeakerCore

public enum SystemAudioCaptureError: LocalizedError {
    case permissionDenied
    case noDisplay
    case unsupportedAudioFormat

    public var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return "Screen & System Audio Recording permission is not active for this build of NoSpeaker Studio. Enable it in System Settings → Privacy & Security → Screen & System Audio Recording, then fully quit and reopen NoSpeaker Studio."
        case .noDisplay: return "No display is available for system-audio capture."
        case .unsupportedAudioFormat: return "The captured system-audio format is unsupported."
        }
    }
}

/// Experimental system-audio-to-trackpad speaker mode.
/// ScreenCaptureKit requires the user's Screen Recording permission even when
/// Studio only consumes audio from the stream.
public final class SystemAudioHapticCapture: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let driver: HapticTrackpadDriver
    // All capture, DSP and playout state is confined to this serial queue.
    // No work is performed on the global event-tap thread.
    private let captureQueue = DispatchQueue(label: "NoSpeakerStudio.SystemAudioCapture", qos: .userInitiated)
    private var stream: SCStream?
    private var processor: LiveSpeechProcessor?
    private var timeline = LiveHapticTimeline()
    private var timer: DispatchSourceTimer?
    private var profile: AudioHapticProfile = .voice
    private var optimized = true
    private var autoGain = true
    private var gate = true
    private var masterLevel: Double = 0.7
    private var accepting = false
    private var expectedPTS: Double?
    private var motorFailureGate = HapticConsecutiveFailureGate()
    private var invalidAudioPackets = 0
    private var onFailure: (@Sendable (String) -> Void)?

    public init(driver: HapticTrackpadDriver) { self.driver = driver }

    public func start(profile: AudioHapticProfile, masterLevel: Double,
                      speechOptimized: Bool = true, automaticGain: Bool = true,
                      noiseGate: Bool = true, bufferSeconds: Double = 0.15,
                      onFailure: @escaping @Sendable (String) -> Void) async throws {
        try Task.checkCancellation()

        if !CGPreflightScreenCaptureAccess() {
            guard CGRequestScreenCaptureAccess() else {
                throw SystemAudioCaptureError.permissionDenied
            }
        }

        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first else { throw SystemAudioCaptureError.noDisplay }
        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        let configuration = SCStreamConfiguration()
        configuration.capturesAudio = true
        configuration.excludesCurrentProcessAudio = true
        configuration.sampleRate = 16_000
        configuration.channelCount = 1
        configuration.width = 2
        configuration.height = 2
        configuration.queueDepth = 3
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 10)
        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: captureQueue)
        try Task.checkCancellation()
        captureQueue.sync {
            self.stream = stream
            self.profile = profile
            self.masterLevel = masterLevel
            self.optimized = speechOptimized
            self.autoGain = automaticGain
            self.gate = noiseGate
            self.onFailure = onFailure
            self.processor = nil
            self.timeline = LiveHapticTimeline(bufferSeconds: bufferSeconds)
            self.expectedPTS = nil
            self.motorFailureGate.reset()
            self.invalidAudioPackets = 0
            self.accepting = true
            let timer = DispatchSource.makeTimerSource(queue: captureQueue)
            timer.schedule(deadline: .now(), repeating: .milliseconds(5), leeway: .milliseconds(1))
            timer.setEventHandler { [weak self] in self?.renderDue() }
            self.timer = timer
            timer.resume()
        }
        do {
            try await stream.startCapture()
            try Task.checkCancellation()
        } catch {
            await stop()
            throw error
        }
    }

    private func renderDue() {
        guard accepting, let frame = timeline.takeDue(now: ProcessInfo.processInfo.systemUptime) else { return }
        do {
            try driver.play(frame, masterLevel: masterLevel)
            motorFailureGate.recordSuccess()
        } catch {
            if motorFailureGate.recordFailure() {
                clearOutput()
                onFailure?("Repeated speaker motor failures: " + error.localizedDescription)
            }
        }
    }

    private func clearOutput() {
        accepting = false
        timer?.cancel()
        timer = nil
        processor = nil
        timeline = LiveHapticTimeline(bufferSeconds: timeline.bufferSeconds)
        expectedPTS = nil
    }

    /// Synchronous output invalidation before closing the shared actuator.
    public func stopOutput() {
        captureQueue.sync { clearOutput() }
    }

    public func stop() async {
        let oldStream = captureQueue.sync { () -> SCStream? in
            clearOutput()
            let previous = stream
            stream = nil
            onFailure = nil
            return previous
        }
        if let oldStream { try? await oldStream.stopCapture() }
    }

    public func stream(_ stream: SCStream, didStopWithError error: any Error) {
        let message = error.localizedDescription
        captureQueue.async { [weak self] in
            guard let self, self.stream === stream, self.accepting else { return }
            self.clearOutput()
            self.onFailure?(message)
        }
    }

    private func rejectAudioPacket() {
        // Never replay a pre-fault partial window or scheduled sound after
        // malformed capture data. A transient format change can recover.
        processor = nil
        timeline = LiveHapticTimeline(bufferSeconds:timeline.bufferSeconds)
        expectedPTS = nil
        invalidAudioPackets = min(3,invalidAudioPackets+1)
        if invalidAudioPackets == 3 {
            clearOutput()
            onFailure?(SystemAudioCaptureError.unsupportedAudioFormat.localizedDescription)
        }
    }

    public func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of outputType: SCStreamOutputType) {
        guard accepting, self.stream === stream, outputType == .audio,
              sampleBuffer.isValid, CMSampleBufferDataIsReady(sampleBuffer) else { return }
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
              let streamDescription = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription) else {
            rejectAudioPacket(); return
        }
        let asbd = streamDescription.pointee
        let channels = Int(asbd.mChannelsPerFrame)
        let planar = (asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0
        let stride = MemoryLayout<Float>.size
        guard asbd.mFormatID == kAudioFormatLinearPCM,
              asbd.mBitsPerChannel == 32,
              (asbd.mFormatFlags & kAudioFormatFlagIsFloat) != 0,
              (asbd.mFormatFlags & kAudioFormatFlagIsBigEndian) == 0,
              asbd.mSampleRate.isFinite, (8_000...96_000).contains(asbd.mSampleRate),
              (1...8).contains(channels),Int(asbd.mBytesPerFrame) == (planar ? stride : channels*stride) else {
            rejectAudioPacket(); return
        }
        let frameCount = CMSampleBufferGetNumSamples(sampleBuffer)
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
        guard frameCount > 0,frameCount <= Int(asbd.mSampleRate*0.5),pts.isFinite else {
            rejectAudioPacket(); return
        }

        var requiredSize = 0
        var retainedBlockBuffer: CMBlockBuffer?
        let firstStatus = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: &requiredSize,
            bufferListOut: nil,
            bufferListSize: 0,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: 0,
            blockBufferOut: &retainedBlockBuffer
        )
        let maxListSize = MemoryLayout<AudioBufferList>.size + 7*MemoryLayout<AudioBuffer>.stride
        guard firstStatus == noErr,requiredSize >= MemoryLayout<AudioBufferList>.size,requiredSize <= maxListSize else {
            rejectAudioPacket(); return
        }

        let raw = UnsafeMutableRawPointer.allocate(byteCount: requiredSize, alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        let list = raw.bindMemory(to: AudioBufferList.self, capacity: 1)
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: list,
            bufferListSize: requiredSize,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: UInt32(kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment),
            blockBufferOut: &retainedBlockBuffer
        )
        guard status == noErr else { rejectAudioPacket(); return }

        var samples = [Float](repeating:0,count:frameCount)
        // Check the reported list count before constructing the variable-
        // length buffer view. Every pointer is validated before reading.
        let bufferCount = Int(list.pointee.mNumberBuffers)
        let expectedBuffers = planar ? channels : 1
        guard bufferCount == expectedBuffers,
              requiredSize >= MemoryLayout<AudioBufferList>.size + (bufferCount-1)*MemoryLayout<AudioBuffer>.stride else {
            rejectAudioPacket(); return
        }
        let audioBuffers = UnsafeMutableAudioBufferListPointer(list)
        if planar {
            for buffer in audioBuffers {
                guard buffer.mNumberChannels == 1,let data = buffer.mData,
                      Int(buffer.mDataByteSize) >= frameCount*stride else { rejectAudioPacket(); return }
                let pointer = data.assumingMemoryBound(to:Float.self)
                for frame in 0..<frameCount {
                    let value = pointer[frame]
                    guard value.isFinite else { rejectAudioPacket(); return }
                    samples[frame] += max(-1,min(1,value))/Float(channels)
                }
            }
        } else {
            guard let buffer = audioBuffers.first,Int(buffer.mNumberChannels) == channels,let data = buffer.mData,
                  Int(buffer.mDataByteSize) >= frameCount*channels*stride else { rejectAudioPacket(); return }
            let pointer = data.assumingMemoryBound(to:Float.self)
            for frame in 0..<frameCount {
                for channel in 0..<channels {
                    let value = pointer[frame*channels+channel]
                    guard value.isFinite else { rejectAudioPacket(); return }
                    samples[frame] += max(-1,min(1,value))/Float(channels)
                }
            }
        }
        invalidAudioPackets = 0
        let sampleRate = asbd.mSampleRate
        let discontinuity = expectedPTS.map { abs(pts - $0) > 0.035 } == true
        if processor?.sampleRate != sampleRate || discontinuity {
            processor = LiveSpeechProcessor(sampleRate: sampleRate, profile: profile,
                speechOptimized: optimized, automaticGain: autoGain, noiseGate: gate)
            timeline = LiveHapticTimeline(bufferSeconds: timeline.bufferSeconds)
        }
        expectedPTS = pts + Double(frameCount) / sampleRate
        let frames = processor?.append(samples) ?? []
        timeline.enqueue(frames, now: ProcessInfo.processInfo.systemUptime)
    }
}
#endif
