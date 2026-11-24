import Foundation
import Testing
@testable import NoSpeakerCore

private func pageRequest(_ text: String) -> RemotePageRequest {
    RemotePageRequest.parse(Data(text.utf8), authority: "127.0.0.1:9444")
}
@Test func remotePageOnlyServesFixedGetAssets() {
    #expect(pageRequest("GET / HTTP/1.1\r\nHost: 127.0.0.1:9444\r\n\r\n") == .page)
    #expect(pageRequest("GET /control.js HTTP/1.1\r\nhost: 127.0.0.1:9444\r\n\r\n") == .script)
    #expect(pageRequest("GET /?token=secret HTTP/1.1\r\nHost: 127.0.0.1:9444\r\n\r\n") == .rejected)
    #expect(pageRequest("POST / HTTP/1.1\r\nHost: 127.0.0.1:9444\r\n\r\n") == .rejected)
}
@Test func remotePageRejectsWrongHostAndRequestBodies() {
    #expect(pageRequest("GET / HTTP/1.1\r\nHost: example.test\r\n\r\n") == .rejected)
    #expect(pageRequest("GET / HTTP/1.1\r\nHost: 127.0.0.1:9444\r\nHost: 127.0.0.1:9444\r\n\r\n") == .rejected)
    #expect(pageRequest("GET / HTTP/1.1\r\nHost: 127.0.0.1:9444\r\nTransfer-Encoding: chunked\r\n\r\n") == .rejected)
    #expect(pageRequest("GET / HTTP/1.1\r\nHost: 127.0.0.1:9444\r\n\r\nmore") == .rejected)
}
@Test func remotePageBoundsIncompleteRequests() {
    #expect(pageRequest("GET / HTTP/1.1\r\nHost: 127.0.0.1:9444") == .incomplete)
    #expect(RemotePageRequest.parse(Data(repeating: 65, count: 8192), authority: "127.0.0.1:9444") == .rejected)
}
