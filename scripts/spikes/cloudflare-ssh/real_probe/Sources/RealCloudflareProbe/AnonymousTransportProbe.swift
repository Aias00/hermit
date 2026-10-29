import CloudflareSSH
import Foundation
import NIOPosix

/// A single system-trusted TLS/WebSocket request, without Access credentials.
/// No SSH consumer is installed and the carrier is never activated.
enum AnonymousTransportProbe {
    static func run(hostname: String) async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        emit("anonymous_transport_started", ["timeout_seconds": 15,
            "access_token_supplied": false, "ssh_payload_sent": false])
        do {
            do {
                let connection = try await CloudflareSSHDialer().connect(
                    endpoint: URL(string: "wss://" + hostname + "/")!, accessToken: nil, on: group,
                    timeout: .seconds(15), onDiagnostic: { event in
                        emit("transport_phase", ["phase": String(describing: event.kind),
                            "elapsed_ms": event.elapsedMilliseconds])
                    })
                // Unexpected anonymous acceptance is evidence to report, never
                // permission to send a banner, authenticate SSH or run commands.
                await connection.close()
                emit("unexpected_anonymous_upgrade", ["http_status": 101,
                    "ssh_payload_sent": false, "g1_complete": false, "g2_complete": false])
                throw ProbeError.unexpectedAnonymousUpgrade
            } catch let error as CloudflareSSHTransportError {
                guard case .httpStatus(let status) = error else { throw error }
                let accessRejection = [301, 302, 303, 307, 308, 401, 403].contains(status)
                emit(accessRejection ? "anonymous_access_rejected" : "anonymous_http_response",
                    ["http_status": status, "access_rejection": accessRejection,
                     "ssh_payload_sent": false, "g1_complete": false, "g2_complete": false])
            }
            try await group.shutdownGracefully()
        } catch {
            try? await group.shutdownGracefully()
            throw error
        }
    }
}
