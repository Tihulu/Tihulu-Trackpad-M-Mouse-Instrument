#if os(macOS)
import Foundation
import NoSpeakerCore

/// Native client diagnostic, not a browser or remote phone. Uses URLSession's
/// normal server certificate validation; no custom challenge/trust handler.
public enum RemoteLoopbackProbe {
    public enum Failure: LocalizedError {
        case invalidInvitation, acknowledgment
        public var errorDescription: String? {
            switch self {
            case .invalidInvitation: "Invalid test invitation."
            case .acknowledgment: "Unexpected response from loopback server."
            }
        }
    }

    public static func run(invitation: Data) async throws {
        guard invitation.count == 32 else { throw Failure.invalidInvitation }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 5
        configuration.timeoutIntervalForResource = 8
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        // Fixed endpoint, not supplied by an untrusted client.
        var request = URLRequest(url: URL(string: "wss://127.0.0.1:9443/")!)
        request.setValue("https://127.0.0.1:9444", forHTTPHeaderField: "Origin")
        request.setValue(RemoteHandshakePolicy.subprotocol, forHTTPHeaderField: "Sec-WebSocket-Protocol")
        let socket = session.webSocketTask(with: request)
        socket.maximumMessageSize = 256
        let timer = Task {
            do { try await Task.sleep(for: .seconds(5)) } catch { return }
            socket.cancel(with: .goingAway, reason: nil)
        }
        defer {
            timer.cancel()
            socket.cancel(with: .normalClosure, reason: nil)
        }
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            socket.resume()
            try await socket.send(.data(invitation))
            try await expect("admitted", from: socket)
            try await socket.send(.string("{\"version\":1,\"sequence\":1,\"kind\":\"touch\",\"x\":0.7,\"y\":0.6}"))
            try await expect("accepted", from: socket)
            try await socket.send(.string("{\"version\":1,\"sequence\":2,\"kind\":\"release\"}"))
            try await expect("accepted", from: socket)
            try Task.checkCancellation()
        } onCancel: {
            socket.cancel(with: .goingAway, reason: nil)
        }
    }

    private static func expect(_ expected: String, from socket: URLSessionWebSocketTask) async throws {
        guard case .string(let response) = try await socket.receive(), response == expected else {
            throw Failure.acknowledgment
        }
    }
}
#endif
