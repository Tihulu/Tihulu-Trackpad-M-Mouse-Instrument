/// Session fence for work received asynchronously. All access must be
/// serialized by the caller (the MIDI service uses its existing state lock).
public struct LegacyReceiveEpoch: Sendable {
    private var generation: UInt64 = 0
    public private(set) var token: UInt64?
    public init() {}
    public mutating func begin() {
        generation &+= 1
        token = generation
    }
    public mutating func end() { token = nil }
    public func accepts(_ captured: UInt64) -> Bool { token == captured }
}
