#if os(macOS)
import Foundation
import Darwin
import NoSpeakerCore

public struct RemoteLANChoice: Identifiable, Equatable, Sendable {
    public let interface: String
    public let endpoint: RemoteEndpoint
    public var id: String { interface + ":" + endpoint.host }

    /// Only explicitly refreshed local active non-loopback IPv4 interfaces.
    /// No discovery broadcast, subnet scan, external requests or persistence.
    public static func available() -> [Self] {
        var first: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&first) == 0, let first else { return [] }
        defer { freeifaddrs(first) }
        var result: [Self] = []
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let current = cursor {
            let entry = current.pointee
            cursor = entry.ifa_next
            guard let address = entry.ifa_addr, address.pointee.sa_family == sa_family_t(AF_INET),
                  (entry.ifa_flags & UInt32(IFF_UP)) != 0,
                  (entry.ifa_flags & UInt32(IFF_RUNNING)) != 0,
                  (entry.ifa_flags & UInt32(IFF_LOOPBACK)) == 0,
                  let name = entry.ifa_name else { continue }
            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let status = buffer.withUnsafeMutableBufferPointer { storage in
                getnameinfo(address, socklen_t(address.pointee.sa_len), storage.baseAddress,
                            socklen_t(storage.count), nil, 0, NI_NUMERICHOST)
            }
            guard status == 0,
                  let endpoint = RemoteEndpoint(host: String(cString: buffer)), !endpoint.isLoopback
            else { continue }
            let choice = Self(interface: String(cString: name), endpoint: endpoint)
            if !result.contains(choice) { result.append(choice) }
        }
        return result.sorted { $0.id < $1.id }
    }
}
#endif
