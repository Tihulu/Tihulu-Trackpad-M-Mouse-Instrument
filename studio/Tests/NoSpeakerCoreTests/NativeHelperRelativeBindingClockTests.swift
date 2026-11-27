import Foundation
import Testing
@testable import NoSpeakerCore

private typealias ClockBinding = NativeHelperRelativeInputBinding
private typealias ClockClutch = NativeHelperRelativeClutch
private struct BindingClockRig {
    let monitor = UUID(), registration = UUID()
    let surface: ClockClutch.Surface
    var binding: ClockBinding
    var sequence: UInt64 = 10
    var calls: [String] = []

    init(_ surface: ClockClutch.Surface) {
        self.surface = surface
        let boundary = NativeHelperRelativeArmBoundary(source: surface, registration: registration,
            afterSequence: 10, afterAcquisitionNS: 0)!
        let config = NativeHelperRelativeSingleChannel(settings: .init(), enabled: [.x],
            channel: 2, vibratoCC: 74, expressionCC: 11)!
        binding = ClockBinding(boundary: boundary, monitor: monitor, configuration: config, orientation: .horizontal)!
    }
    mutating func feed(_ acquired: Int64, x: Double? = nil, times: [Int64]? = nil,
                       seq: UInt64? = nil, missing: Bool = false, wrongFrame: Bool = false,
                       foreign: Bool = false) -> ClockBinding.Result {
        if seq == nil { sequence += 1 }
        let frameSurface: ClockClutch.Surface = wrongFrame ? (surface == .trackpad ? .magicMouse : .trackpad) : surface
        let contacts: [ClockClutch.Contact] = x.map { [.init(surface: frameSurface, id: 1, x: $0, y: 0.5, contactSize: 0.5)] } ?? []
        let frame = ClockClutch.SourceFrame(surface: frameSurface, rawDownCount: contacts.count,
            sourceConsistent: true, contacts: contacts, receipt: Double(acquired)/1e9,
            nativeRegistration: registration, acquisitionNS: acquired)
        let samples = times ?? [acquired]
        var index = 0, log: [String] = []
        let result = binding.receive(missing ? nil : frame, source: surface, monitor: foreign ? UUID() : monitor,
            sequence: seq ?? sequence, clock: {
                defer { index += 1 }; return samples[min(index, samples.count-1)]
            }, live: { true }, activeLeaseValid: { true }, begin: { _, permits in
                guard permits() else { return false }; log.append("begin"); return true
            }, move: { _, permits in
                guard permits() else { return false }; log.append("move"); return true
            }, retire: { neutral, _ in log.append("retire:\(neutral)"); return true })
        calls += log
        return result
    }
    mutating func poll(_ now: Int64) -> ClockBinding.Result {
        var log: [String] = []
        let result = binding.poll(nowNS: now, live: true, retire: { neutral, _ in log.append("retire:\(neutral)"); return true })
        calls += log; return result
    }
}

@Test(arguments: [ClockClutch.Surface.trackpad, .magicMouse], [Int64(1_000_000_000), 100_000_000_000, 100_000_000_000_000, 100_000_000_000_000_000])
func relativeBindingIntegerWatchdogAndDelayedFrame(surface: NativeHelperRelativeClutch.Surface, base: Int64) {
    for offset in 0..<256 {
        let anchor = base+31_250_000+Int64(offset)*1024
        for delta: Int64 in [149_999_999, 150_000_000, 150_000_001] {
            for watchdog in [false, true] {
                var r = BindingClockRig(surface)
                #expect(r.feed(base) == .waiting)
                #expect(r.feed(anchor, x: 0.5) == .anchored)
                let now = anchor+delta
                let result = watchdog ? r.poll(now) : r.feed(now-32_000_000, x: 0.75, times: [now])
                let expired = delta >= 150_000_000
                #expect(result == (expired ? .retired : (watchdog ? .ignored : .accepted)))
                #expect(r.calls == (expired ? ["retire:true", "begin", "retire:false"] : (watchdog ? ["retire:true", "begin"] : ["retire:true", "begin", "move"])))
            }
        }
    }
}

@Test(arguments: [ClockClutch.Surface.trackpad, .magicMouse], Array(0..<3))
func relativeBindingClockHighWaterIncludesEveryPermit(surface: NativeHelperRelativeClutch.Surface, stage: Int) {
    let base: Int64 = 1_000_000_000
    var r = BindingClockRig(surface)
    #expect(r.feed(base) == .waiting)
    let anchor = base+32_000_000
    if stage == 0 {
        // First permit regresses relative to the initial receive clock.
        #expect(r.feed(anchor, x: 0.5, times: [anchor+2, anchor+1, anchor+3]) == .retired)
        #expect(r.calls == ["retire:true", "retire:false"])
    } else {
        #expect(r.feed(anchor, x: 0.5, times: [anchor, anchor+2]) == .anchored)
        if stage == 1 {
            #expect(r.poll(anchor+1) == .retired)
        } else {
            #expect(r.feed(anchor+1, x: 0.75, times: [anchor+1, anchor+3]) == .retired)
        }
        #expect(r.calls == ["retire:true", "begin", "retire:false"])
    }
    let later = anchor+64_000_000
    #expect(r.feed(later, x: 0.75) == .waiting)
    #expect(r.feed(later+32_000_000) == .waiting)
    #expect(r.feed(later+64_000_000, x: 0.5) == .anchored)
}

@Test(arguments: [ClockClutch.Surface.trackpad, .magicMouse], Array(0..<3))
func relativeBindingIgnoresExcludedMalformedPublications(surface: NativeHelperRelativeClutch.Surface, shape: Int) {
    let base: Int64 = 1_000_000_000
    var r = BindingClockRig(surface)
    for seq: UInt64 in [9, 10] {
        #expect(r.feed(base, seq: seq, missing: shape == 1, wrongFrame: shape == 2) == .ignored)
    }
    #expect(r.feed(base, seq: 1000, missing: true, foreign: true) == .ignored)
    #expect(r.calls.isEmpty)
    #expect(r.feed(base) == .waiting)
    #expect(r.feed(base+32_000_000, x: 0.5) == .anchored)
    #expect(r.feed(base+64_000_000, seq: 12, missing: shape == 1, wrongFrame: shape == 2) == .ignored)
    #expect(r.feed(base+96_000_000, x: 0.75) == .accepted)
    #expect(r.feed(base+128_000_000, missing: true) == .retired)
    #expect(r.feed(base+160_000_000) == .ignored)
    #expect(r.calls == ["retire:true", "begin", "move", "retire:false"])
}
