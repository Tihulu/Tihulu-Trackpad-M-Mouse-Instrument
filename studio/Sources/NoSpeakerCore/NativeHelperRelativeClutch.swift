import Foundation

/// Portable single-contact planner for the legacy native helper. Does not
/// own the MIDI port, send messages, or certify receiver feedback. The host
/// must serialize calls, supply complete accepted frames, and apply its
/// existing ownership, freshness, release and emergency gates.
public struct NativeHelperRelativeClutch: Sendable {
    public enum Surface: String, Sendable { case trackpad, magicMouse }
    public enum Axis: String, CaseIterable, Hashable, Sendable { case x, y, contactSize }
    public struct Contact: Sendable {
        public let surface: Surface
        public let id: Int
        public let x, y, contactSize: Double
        public init(surface: Surface, id: Int, x: Double, y: Double, contactSize: Double) {
            self.surface = surface; self.id = id
            self.x = x; self.y = y; self.contactSize = contactSize
        }
        fileprivate func value(_ axis: Axis) -> Double {
            switch axis { case .x: x; case .y: y; case .contactSize: contactSize }
        }
        fileprivate var valid: Bool {
            id >= 0 && [x,y,contactSize].allSatisfy { $0.isFinite && (0...1).contains($0) }
        }
    }
    public struct Lane: Sendable {
        public let reference, lower, upper: Int
        public let gain: Double
        public let smoothingMS: Int
        public init(reference: Int, lower: Int = 0, upper: Int, gain: Double = 1, smoothingMS: Int = 0) {
            self.reference = reference; self.lower = lower; self.upper = upper
            self.gain = gain; self.smoothingMS = smoothingMS
        }
        fileprivate func gesture(input: Double, time: Double) -> RelativeControlGesture? {
            .init(input: input, timestamp: time, reference: reference, lower: lower, upper: upper,
                  gain: gain, smoothingMS: smoothingMS)
        }
    }
    public enum Result: Equatable, Sendable {
        case idle, anchored, movement([Axis:Int]), releaseRequired, blocked
    }
    private enum Phase: Sendable { case waitingForNeutral, ready, active(Int), blocked }
    private let surface: Surface
    private let lanes: [Axis:Lane]
    private var phase: Phase = .waitingForNeutral
    private var gestures: [Axis:RelativeControlGesture] = [:]
    private var lastReceipt: Double?
    public init?(surface: Surface, lanes: [Axis:Lane]) {
        guard !lanes.isEmpty, lanes.values.allSatisfy({ $0.gesture(input: 0, time: 0) != nil }) else { return nil }
        self.surface = surface; self.lanes = lanes
    }
    /// Explicit invalidation for mapping/permission/identity loss. The host
    /// must release existing output and wait for genuine neutral input.
    public mutating func invalidate() -> Result {
        let wasActive: Bool
        if case .active = phase { wasActive = true } else { wasActive = false }
        gestures.removeAll()
        phase = .blocked
        return wasActive ? .releaseRequired : .blocked
    }
    /// Complete source-local frame, not a cached multi-surface snapshot.
    /// A second finger or changed contact ID invalidates the entire clutch.
    public mutating func frame(_ contacts: [Contact], receipt: Double) -> Result {
        guard receipt.isFinite, receipt >= 0,
              lastReceipt.map({ receipt > $0 }) ?? true else { return invalidate() }
        lastReceipt = receipt
        guard contacts.count <= 1, contacts.allSatisfy({ $0.surface == surface && $0.valid }) else { return invalidate() }
        guard let contact = contacts.first else {
            let wasActive: Bool
            if case .active = phase { wasActive = true } else { wasActive = false }
            gestures.removeAll(); phase = .ready
            return wasActive ? .releaseRequired : .idle
        }
        switch phase {
        case .waitingForNeutral, .blocked: return .blocked
        case .ready:
            var next: [Axis:RelativeControlGesture] = [:]
            for (axis,lane) in lanes {
                guard let gesture = lane.gesture(input: contact.value(axis), time: receipt) else { return invalidate() }
                next[axis] = gesture
            }
            gestures = next; phase = .active(contact.id)
            return .anchored
        case .active(let id):
            guard contact.id == id else { return invalidate() }
            var output: [Axis:Int] = [:]
            for axis in Axis.allCases {
                guard var gesture = gestures[axis] else { continue }
                if let value = gesture.update(input: contact.value(axis), timestamp: receipt) { output[axis] = value }
                gestures[axis] = gesture
            }
            return output.isEmpty ? .idle : .movement(output)
        }
    }
}
