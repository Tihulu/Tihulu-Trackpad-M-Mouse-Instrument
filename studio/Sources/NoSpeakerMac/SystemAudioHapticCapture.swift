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
        try? driver.play(frame, masterLevel: masterLevel)
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

    public func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of outputType: SCStreamOutputType) {
        guard accepting, self.stream === stream, outputType == .audio,
              sampleBuffer.isValid, CMSampleBufferDataIsReady(sampleBuffer) else { return }
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
              let streamDescription = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription) else { return }
        let asbd = streamDescription.pointee
        guard asbd.mFormatID == kAudioFormatLinearPCM,
              asbd.mBitsPerChannel == 32,
              (asbd.mFormatFlags & kAudioFormatFlagIsFloat) != 0,
              asbd.mSampleRate.isFinite, (8_000...96_000).contains(asbd.mSampleRate) else { return }

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
        guard firstStatus == noErr, requiredSize > 0 else { return }

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
        guard status == noErr else { return }

        var samples: [Float] = []
        let audioBuffers = UnsafeMutableAudioBufferListPointer(list)
        let frameCount = CMSampleBufferGetNumSamples(sampleBuffer)
        guard frameCount > 0, frameCount <= Int(asbd.mSampleRate * 0.5) else { return }
        samples.reserveCapacity(frameCount)
        if asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0 {
            guard let buffer = audioBuffers.first, let first = buffer.mData,
                  Int(buffer.mDataByteSize) >= frameCount * MemoryLayout<Float>.size else { return }
            let pointer = first.assumingMemoryBound(to: Float.self)
            samples.append(contentsOf: UnsafeBufferPointer(start: pointer, count: frameCount))
        } else {
            let channels = Int(asbd.mChannelsPerFrame)
            guard (1...8).contains(channels), let buffer = audioBuffers.first, let first = buffer.mData,
                  Int(buffer.mDataByteSize) >= frameCount * channels * MemoryLayout<Float>.size else { return }
            let pointer = first.assumingMemoryBound(to: Float.self)
            for frame in 0..<frameCount {
                var mono: Float = 0
                for channel in 0..<channels { mono += pointer[frame * channels + channel] / Float(channels) }
                samples.append(mono)
            }
        }
        let sampleRate = asbd.mSampleRate
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
        let discontinuity = pts.isFinite && expectedPTS.map { abs(pts - $0) > 0.035 } == true
        if processor?.sampleRate != sampleRate || discontinuity {
            processor = LiveSpeechProcessor(sampleRate: sampleRate, profile: profile,
                speechOptimized: optimized, automaticGain: autoGain, noiseGate: gate)
            timeline = LiveHapticTimeline(bufferSeconds: timeline.bufferSeconds)
        }
        expectedPTS = pts.isFinite ? pts + Double(frameCount) / sampleRate : nil
        let frames = processor?.append(samples) ?? []
        timeline.enqueue(frames, now: ProcessInfo.processInfo.systemUptime)
    }
}
#endif
