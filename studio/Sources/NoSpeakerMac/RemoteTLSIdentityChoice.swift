#if os(macOS)
import Foundation
import Security
import NoSpeakerCore

/// Explicit selection of an already-provisioned Keychain identity. No private
/// key export, certificate generation, import or trust-settings changes.
@MainActor
public struct RemoteTLSIdentityChoice: Identifiable {
    public let id = UUID()
    public let name: String
    private let identity: SecIdentity
    public enum Failure: LocalizedError {
        case keychain, untrusted
        public var errorDescription: String? {
            switch self {
            case .keychain: "Could not enumerate Keychain identities."
            case .untrusted: "The selected identity is not trusted for the selected numeric TLS server address. Check the certificate and its trust chain in Keychain Access."
            }
        }
    }

    public static func available() throws -> [Self] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassIdentity,
            kSecReturnRef as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess, let identities = result as? [SecIdentity] else { throw Failure.keychain }
        return identities.compactMap { identity in
            var certificate: SecCertificate?
            guard SecIdentityCopyCertificate(identity, &certificate) == errSecSuccess,
                  let certificate else { return nil }
            let name = SecCertificateCopySubjectSummary(certificate) as String? ?? "Unnamed certificate"
            return Self(name: name, identity: identity)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    public func makeLoopbackPageServer(endpoint: RemoteEndpoint = .loopback) throws -> RemoteLoopbackPageServer {
        try RemoteLoopbackPageServer(identity: identity, endpoint: endpoint)
    }

    public func makeLoopbackTransport(endpoint: RemoteEndpoint = .loopback) throws -> RemoteLoopbackTransport {
        var certificate: SecCertificate?
        guard SecIdentityCopyCertificate(identity, &certificate) == errSecSuccess,
              let certificate else { throw Failure.keychain }
        let policy = SecPolicyCreateSSL(true, endpoint.host as CFString)
        var trust: SecTrust?
        guard SecTrustCreateWithCertificates(certificate, policy, &trust) == errSecSuccess,
              let trust, SecTrustSetNetworkFetchAllowed(trust, false) == errSecSuccess,
              SecTrustEvaluateWithError(trust, nil) else { throw Failure.untrusted }
        return try RemoteLoopbackTransport(identity: identity, endpoint: endpoint)
    }
}
#endif
