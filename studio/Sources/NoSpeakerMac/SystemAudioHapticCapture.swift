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
    private let captureQueue = DispatchQueue(label: "NoSpeakerStudio.SystemAudioCapture", qos: .userInteractive)
    private let processingQueue = DispatchQueue(label: "NoSpeakerStudio.SystemAudioProcessing", qos: .userInitiated)
    private var stream: SCStream?
    private var profile: AudioHapticProfile = .fullMix
    private var masterLevel: Double = 0.7
    private var isRunning = false

    public init(driver: HapticTrackpadDriver) { self.driver = driver }

    public func start(profile: AudioHapticProfile, masterLevel: Double) async throws {
        if isRunning { return }
        self.profile = profile
        self.masterLevel = masterLevel

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
        self.stream = stream
        try await stream.startCapture()
        isRunning = true
    }

    public func stop() async {
        guard let stream else { return }
        try? await stream.stopCapture()
        self.stream = nil
        isRunning = false
    }

    public func stream(_ stream: SCStream, didStopWithError error: any Error) {
        isRunning = false
    }

    public func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of outputType: SCStreamOutputType) {
        guard outputType == .audio, sampleBuffer.isValid, CMSampleBufferDataIsReady(sampleBuffer) else { return }
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
              let streamDescription = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription) else { return }
        let asbd = streamDescription.pointee
        guard asbd.mFormatID == kAudioFormatLinearPCM,
              asbd.mBitsPerChannel == 32,
              (asbd.mFormatFlags & kAudioFormatFlagIsFloat) != 0 else { return }

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
        samples.reserveCapacity(frameCount)
        if asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0 {
            guard let first = audioBuffers.first?.mData else { return }
            let pointer = first.assumingMemoryBound(to: Float.self)
            samples.append(contentsOf: UnsafeBufferPointer(start: pointer, count: frameCount))
        } else {
            guard let first = audioBuffers.first?.mData else { return }
            let channels = max(1, Int(asbd.mChannelsPerFrame))
            let pointer = first.assumingMemoryBound(to: Float.self)
            for frame in 0..<frameCount {
                var mono: Float = 0
                for channel in 0..<channels { mono += pointer[frame * channels + channel] / Float(channels) }
                samples.append(mono)
            }
        }
        let capturedSamples = samples
        let sampleRate = asbd.mSampleRate
        let profile = self.profile
        let level = self.masterLevel
        processingQueue.async { [weak self] in
            guard let self else { return }
            let events = HapticSignalProcessor.hapticEvents(samples: capturedSamples, sampleRate: sampleRate, profile: profile)
            for event in events.prefix(12) {
                var frame = event.frame
                frame.level *= level
                try? self.driver.play(frame)
            }
        }
    }
}
#endif
