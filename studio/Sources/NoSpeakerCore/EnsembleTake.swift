import Foundation

/// Bounded capture of reconciled Builder MIDI commands, not raw sensor
/// samples, remote identity, video or proof of DAW delivery.
public struct EnsembleTake: Sendable {
    public struct Event: Equatable, Sendable {
        public let tick: Int
        public let command: SensorCommand
    }
    public static let maximumDuration = 120.0
    public static let maximumEvents = 32_768
    public let bpm: Double
    private let origin: Double
    private let releases: [SensorDestination:Int]
    private var outstanding: [SensorDestination:Int] = [:]
    private var lastTime: Double
    public private(set) var events: [Event] = []
    public private(set) var endTick: Int?
    public private(set) var truncated = false
    public init?(patch:InstrumentPatch,bpm:Double,now:Double) {
        guard patch.isValid,!patch.routes.isEmpty,bpm.isFinite,(20...300).contains(bpm),
              now.isFinite,now >= 0,now < 1e12,
              let releases = ContinuousResponse.releaseValues(for:patch.routes) else { return nil }
        self.bpm = bpm; self.origin = now; self.lastTime = now; self.releases = releases
    }
    private func tick(_ time:Double) -> Int {
        Int(((time-origin)*bpm/60*Double(MIDIClip.ppq)).rounded())
    }
    /// On capacity/time failure finish the take, not the live performance.
    @discardableResult
    public mutating func append(_ command:SensorCommand,now:Double) -> Bool {
        guard endTick == nil else { return false }
        checkTime(now:now)
        guard endTick == nil else { return false }
        guard now.isFinite,now >= lastTime,now-origin < Self.maximumDuration,
              events.count < Self.maximumEvents-SensorRouter.maxMappings,
              let release = releases[command.destination],
              (0...(command.destination.kind == .pitchBend ? 16383 : 127)).contains(command.value)
        else { truncated = true; finish(now:lastTime); return false }
        events.append(.init(tick:tick(now),command:command))
        if command.value == release { outstanding.removeValue(forKey:command.destination) }
        else { outstanding[command.destination] = command.value }
        lastTime = now
        return true
    }
    public mutating func checkTime(now:Double) {
        guard endTick == nil else { return }
        if !now.isFinite || now < lastTime { truncated = true; finish(now:lastTime) }
        else if now-origin >= Self.maximumDuration { truncated = true; finish(now:origin+Self.maximumDuration) }
    }
    public mutating func interrupt(now:Double) {
        guard endTick == nil else { return }
        truncated = true
        finish(now:now)
    }
    public mutating func finish(now:Double) {
        guard endTick == nil else { return }
        let safe = now.isFinite ? max(lastTime,min(now,origin+Self.maximumDuration)) : lastTime
        // Reserve an extra tick for closure, even if a note was just started.
        let final = max(tick(safe), (events.last?.tick ?? -1)+1)
        let keys = outstanding.keys.sorted {
            if $0.channel != $1.channel { return $0.channel < $1.channel }
            // Note-off before sustain-off, then release continuous controls.
            func rank(_ d:SensorDestination) -> Int {
                switch d.kind { case .note:0;case .sustain:1;case .pitchBend:2;case .controlChange:3 }
            }
            if rank($0) != rank($1) { return rank($0) < rank($1) }
            return $0.number < $1.number
        }
        for d in keys { if let value = releases[d] { events.append(.init(tick:final,command:.init(d,value:value))) } }
        outstanding.removeAll()
        endTick = max(1,final)
    }

    /// SMF type 1: tempo track plus one track per used MIDI channel.
    /// Same-tick events retain reconciled order within their channel.
    public func encoded() throws -> Data {
        guard let endTick,!events.isEmpty else { throw MIDIClipError.empty }
        func be(_ value:Int,_ count:Int)->[UInt8] {
            (0..<count).reversed().map { UInt8((value >> ($0*8)) & 255) }
        }
        func vlq(_ value:Int)->[UInt8] {
            var n = value; var bytes = [UInt8(n & 127)]; n >>= 7
            while n > 0 { bytes.append(UInt8(n & 127)|128); n >>= 7 }
            return Array(bytes.reversed())
        }
        func chunk(_ track:[UInt8])->[UInt8] {
            Array("MTrk".utf8)+be(track.count,4)+track
        }
        let groups = Dictionary(grouping:events,by:{ $0.command.destination.channel })
        var file = Array("MThd".utf8)+be(6,4)+be(1,2)+be(groups.count+1,2)+be(MIDIClip.ppq,2)
        var tempo:[UInt8] = [0,0xFF,0x51,3]
        tempo += be(Int((60_000_000/bpm).rounded()),3)
        tempo += vlq(endTick)+[0xFF,0x2F,0]
        file += chunk(tempo)
        for ch in groups.keys.sorted() {
            var track:[UInt8] = []; var previous = 0
            for event in groups[ch] ?? [] {
                let d = event.command.destination; let v = event.command.value
                track += vlq(event.tick-previous)
                switch d.kind {
                case .note: track += [UInt8((v == 0 ? 0x80 : 0x90)|ch),UInt8(d.number),UInt8(v)]
                case .sustain: track += [UInt8(0xB0|ch),64,UInt8(v)]
                case .controlChange: track += [UInt8(0xB0|ch),UInt8(d.number),UInt8(v)]
                case .pitchBend: track += [UInt8(0xE0|ch),UInt8(v & 127),UInt8(v >> 7)]
                }
                previous = event.tick
            }
            track += vlq(endTick-previous)+[0xFF,0x2F,0]
            file += chunk(track)
        }
        return Data(file)
    }
}
