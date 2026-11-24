import Foundation

/// Explicit browser origin/authority allowlist. No wildcard, null, reflection
/// or suffix matching. Host supplies the exact trusted HTTPS page origin.
public struct RemoteHandshakePolicy: Sendable {
    public let authority: String
    public let origin: String
    public static let subprotocol = "tihulu-touch-v1"

    public init?(authority: String, origin: String) {
        guard !authority.isEmpty, authority.utf8.count <= 255,
              !authority.contains(where: { $0.isWhitespace }),
              let endpoint = URLComponents(string: "https://" + authority),
              endpoint.host != nil, endpoint.user == nil, endpoint.password == nil,
              endpoint.path.isEmpty, endpoint.query == nil, endpoint.fragment == nil,
              let page = URLComponents(string: origin), page.scheme == "https",
              page.host != nil, page.user == nil, page.password == nil,
              page.path.isEmpty, page.query == nil, page.fragment == nil,
              origin.utf8.count <= 512 else { return nil }
        self.authority = authority
        self.origin = origin
    }

    public func permits(protocols: [String], headers: [(name: String, value: String)]) -> Bool {
        guard protocols == [Self.subprotocol], headers.count <= 32,
              headers.allSatisfy({ $0.name.utf8.count <= 128 && $0.value.utf8.count <= 2048 })
        else { return false }
        let hosts = headers.filter { $0.name.lowercased() == "host" }
        let origins = headers.filter { $0.name.lowercased() == "origin" }
        return hosts.count == 1 && origins.count == 1 &&
            hosts[0].value == authority && origins[0].value == origin
    }
}

/// Before R1 admission a connection gets exactly one binary invitation.
/// Subsequent data must be text frames with the existing bounded JSON schema.
public struct RemoteConnectionGate: Sendable {
    public enum Phase: Equatable, Sendable { case pending, awaitingHost, admitted, closed }
    public private(set) var phase: Phase = .pending
    private let openedAt: Double
    private var lastDelivery: Double
    public init(now: Double) { openedAt = now; lastDelivery = now }
    public mutating func receiveInvitation(_ data: Data, binary: Bool, now: Double) -> Bool {
        guard phase == .pending, binary, data.count == 32, !expired(now: now)
        else { phase = .closed; return false }
        phase = .awaitingHost
        lastDelivery = now
        return true
    }
    public mutating func admit(now: Double) -> Bool {
        guard phase == .awaitingHost, !expired(now: now)
        else { phase = .closed; return false }
        phase = .admitted
        lastDelivery = now
        return true
    }
    public mutating func receiveFrame(_ data: Data, text: Bool, now: Double) -> Bool {
        guard phase == .admitted, text, !expired(now: now),
              data.count <= RemoteTouchFrame.maximumBytes,
              (try? RemoteTouchFrame.read(data)) != nil
        else { phase = .closed; return false }
        lastDelivery = now
        return true
    }
    public func expired(now: Double) -> Bool {
        guard now.isFinite, openedAt.isFinite, openedAt >= 0, now >= lastDelivery else { return true }
        switch phase {
        case .pending, .awaitingHost: return now-openedAt >= 5
        case .admitted: return now-lastDelivery >= 2
        case .closed: return true
        }
    }
}
