import Foundation

/// Bounded, in-memory, opt-in diagnostic trace. No images or identifiers.
public struct AirFrameTrace: Sendable {
    public enum Mode: Equatable, Sendable { case dual, combined(swapRoles:Bool) }
    public struct Frame: Sendable {
        public let offset: Double
        public let count: Int?
        public let confidence: Double
        public let helper: AirHandSample?
        public let left: AirHandSample?
        public let right: AirHandSample?
    }
    public static let maximumFrames = 600
    public static let maximumDuration = 30.0
    public private(set) var frames: [Frame] = []
    public private(set) var mode: Mode?
    private var origin: Double?
    private var last: Double?
    public init() {}

    /// A rejected clock/capacity ends recording. Invalid landmarks are
    /// recorded as loss, never silently omitted from a valid timeline.
    @discardableResult
    public mutating func append(count: Int?, confidence: Double, helper: AirHandSample?,
                                time: Double) -> Bool {
        guard mode == nil || mode == .dual,
              time.isFinite, time >= 0, last.map({ time > $0 }) ?? true,
              frames.count < Self.maximumFrames else { return false }
        let start = origin ?? time
        let offset = time - start
        guard offset <= Self.maximumDuration else { return false }
        let valid = count.map { (0...5).contains($0) } == true &&
            confidence.isFinite && (0.75...1).contains(confidence) && helper != nil
        frames.append(.init(offset: offset, count: valid ? count : nil,
                            confidence: valid ? confidence : 0, helper: valid ? helper : nil,left:nil,right:nil))
        mode = .dual
        origin = start; last = time
        return true
    }

    @discardableResult
    public mutating func appendCombined(count:Int?,confidence:Double,left:AirHandSample?,right:AirHandSample?,
                                        swapRoles:Bool,time:Double) -> Bool {
        let next = Mode.combined(swapRoles:swapRoles)
        guard mode == nil || mode == next, time.isFinite,time >= 0,
              last.map({ time > $0 }) ?? true,frames.count < Self.maximumFrames else { return false }
        let start = origin ?? time
        let offset = time-start
        guard offset <= Self.maximumDuration else { return false }
        let valid = count.map { (0...5).contains($0) } == true && confidence.isFinite && (0.75...1).contains(confidence)
        // A missing chord count must not discard the surviving helper hand.
        frames.append(.init(offset:offset,count:valid ? count : nil,confidence:valid ? confidence : 0,
                            helper:nil,left:left,right:right))
        mode = next; origin = start; last = time
        return true
    }
}
