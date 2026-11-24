import Foundation

/// Canonical numeric IPv4 only. No DNS resolution, public/wildcard bind,
/// link-local or other loopback aliases. LAN is explicitly RFC1918 only.
public struct RemoteEndpoint: Equatable, Sendable {
    public let host: String
    public static let loopback = RemoteEndpoint(host: "127.0.0.1")!
    public var isLoopback: Bool { host == "127.0.0.1" }
    public var pageAuthority: String { host + ":9444" }
    public var socketAuthority: String { host + ":9443" }
    public var origin: String { "https://" + pageAuthority }
    public var pageURL: String { origin + "/" }
    public var socketURL: String { "wss://" + socketAuthority + "/" }

    public init?(host: String) {
        let pieces = host.split(separator: ".", omittingEmptySubsequences: false)
        guard pieces.count == 4 else { return nil }
        var octets: [UInt8] = []
        for piece in pieces {
            guard !piece.isEmpty, piece.utf8.allSatisfy({ (48...57).contains($0) }),
                  let n = UInt8(piece), String(n) == piece else { return nil }
            octets.append(n)
        }
        let privateAddress = octets[0] == 10 ||
            (octets[0] == 172 && (16...31).contains(octets[1])) ||
            (octets[0] == 192 && octets[1] == 168)
        guard host == "127.0.0.1" || privateAddress else { return nil }
        self.host = host
    }
}
