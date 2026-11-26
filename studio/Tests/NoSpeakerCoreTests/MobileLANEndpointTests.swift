import Foundation
import Testing
@testable import NoSpeakerCore

@Test func mobileLANEndpointCanonicalQRAndExactOrigin() throws {
    for host in ["10.0.0.2","172.16.1.3","172.31.255.254","192.168.1.25"] {
        let endpoint=try #require(MobileLANEndpoint(pageAddress:"https://"+host+":9444/"))
        #expect(endpoint.socketURL=="wss://"+host+":9443/")
        #expect(endpoint.origin=="https://"+host+":9444")
        #expect(endpoint.subprotocol=="tihulu-touch-v1")
    }
}
@Test func mobileLANEndpointRejectsUnexpectedAuthorityAndSecretInURL() {
    for input in ["https://127.0.0.1:9444/","http://192.168.1.25:9444/","https://192.168.01.25:9444/",
                  "https://192.168.1.25:9444/?token=abc","https://192.168.1.25:9444/#abc",
                  "https://192.168.1.25:9444","https://192.168.1.25:9443/","https://8.8.8.8:9444/",
                  "https://192.168.1.25.evil.test:9444/","https://u@192.168.1.25:9444/",
                  "https://172.32.0.1:9444/","https://[::1]:9444/"," https://192.168.1.25:9444/"] {
        #expect(MobileLANEndpoint(pageAddress:input)==nil)
    }
}
@Test func mobileLANInvitationIsExactBinaryAndNotAURL() {
    let token=String(repeating:"aB",count:32)
    #expect(MobileLANEndpoint.invitationBytes(token)==Data(repeating:0xab,count:32))
    for bad in [token+" ",String(token.dropLast()),String(repeating:"g",count:64),"https://"+token,String(repeating:"é",count:32)] {
        #expect(MobileLANEndpoint.invitationBytes(bad)==nil)
    }
}
