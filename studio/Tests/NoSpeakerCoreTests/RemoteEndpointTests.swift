import Testing
@testable import NoSpeakerCore

@Test func remoteEndpointAllowsOnlyCanonicalPrivateIPv4AndLoopback() throws {
    for host in ["10.0.0.1","172.16.0.1","172.31.255.1","192.168.0.1","127.0.0.1"] {
        #expect(RemoteEndpoint(host: host) != nil)
    }
    for host in ["0.0.0.0","127.0.0.2","8.8.8.8","169.254.0.1","172.15.0.1","172.32.0.1","::","localhost","010.0.0.1","192.168.1.256","192.168.1.1:9444","192.168.1.1/path"," 10.0.0.1","192.168.1.1\n"] {
        #expect(RemoteEndpoint(host: host) == nil)
    }
}

@Test func remoteEndpointBuildsExactSeparateAuthorities() throws {
    let endpoint = try #require(RemoteEndpoint(host: "192.168.1.42"))
    #expect(endpoint.pageURL == "https://192.168.1.42:9444/")
    #expect(endpoint.socketURL == "wss://192.168.1.42:9443/")
    #expect(!endpoint.isLoopback)
    let policy = try #require(RemoteHandshakePolicy(authority: endpoint.socketAuthority, origin: endpoint.origin))
    #expect(policy.permits(protocols: [RemoteHandshakePolicy.subprotocol], headers: [("Host",endpoint.socketAuthority),("Origin",endpoint.origin)]))
    #expect(!policy.permits(protocols: [RemoteHandshakePolicy.subprotocol], headers: [("Host",endpoint.socketAuthority),("Origin",RemoteEndpoint.loopback.origin)]))
}
