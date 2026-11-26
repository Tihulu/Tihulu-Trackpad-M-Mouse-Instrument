import Foundation

/// Native input contract only. It is not certificate validation, pairing,
/// discovery or a WebSocket implementation. QR contains the exact page URL,
/// never a secret. The mobile client must authenticate TLS independently.
public struct MobileLANEndpoint: Equatable, Sendable {
    public let endpoint: RemoteEndpoint
    public init?(pageAddress: String) {
        guard pageAddress.utf8.count <= 64, pageAddress.hasPrefix("https://"),
              pageAddress.hasSuffix(":9444/") else {return nil}
        let host=String(pageAddress.dropFirst(8).dropLast(6))
        guard let endpoint=RemoteEndpoint(host:host),!endpoint.isLoopback,
              endpoint.pageURL==pageAddress else {return nil}
        self.endpoint=endpoint
    }
    public var socketURL:String {endpoint.socketURL}
    public var origin:String {endpoint.origin}
    public var subprotocol:String {RemoteHandshakePolicy.subprotocol}

    /// Explicit separate 64-character invitation. Never log or persist it.
    /// Caller owns its lifetime and must send it only after trusted TLS and
    /// exact subprotocol are confirmed for the current socket.
    public static func invitationBytes(_ token:String)->Data? {
        let chars=Array(token.utf8)
        guard chars.count==64 else {return nil}
        func nibble(_ v:UInt8)->UInt8? {
            switch v {case 48...57:return v-48;case 65...70:return v-55;case 97...102:return v-87;default:return nil}
        }
        var bytes=Data();bytes.reserveCapacity(32)
        for i in stride(from:0,to:64,by:2) {
            guard let high=nibble(chars[i]),let low=nibble(chars[i+1]) else {return nil}
            bytes.append(high<<4|low)
        }
        return bytes
    }
}
