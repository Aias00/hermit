import Citadel
import CloudflareAccess
import CloudflareSSH
import Foundation
import NIOCore
import Testing

@testable import Moshpit

/// The troubleshooting page promises "plain language, not stderr" — that the
/// messages are rewritten from the raw library errors so they say something
/// actionable. These tests hold that promise to account.
///
/// It was not being kept. Pointing a screenshot run at an unroutable address
/// produced an alert reading:
///
///     SSH error: The operation couldn't be completed.
///     (Citadel.ClientHandshakeHandler.(unknown context at $105f91dd4).
///     (unknown context at $105f91de0).Disconnected error 1.)
///
/// — pointer addresses and an internal type name, shown to a user, on the one
/// path a new user is most likely to hit first.
@Suite("SSH error mapping")
struct SSHErrorMappingTests {

    /// Stands in for a Citadel/NIO error, which cannot be constructed here.
    /// The classifier reads `String(describing:)`, so reproducing the text is
    /// what matters.
    private struct OpaqueError: Error, CustomStringConvertible {
        let description: String
    }

    @Test("a handshake that drops is explained, not dumped")
    func handshakeDisconnect() {
        let raw = OpaqueError(description:
            "Citadel.ClientHandshakeHandler.(unknown context at $105f91dd4)."
            + "(unknown context at $105f91de0).Disconnected error 1.")
        let mapped = SSHError.map(raw)

        #expect(mapped.isHandshakeFailed)
        let message = mapped.description
        #expect(!message.contains("Citadel"))
        #expect(!message.contains("$"))
        #expect(!message.contains("unknown context"))
    }

    @Test("known connection failures keep distinct classifications regardless of UI language")
    func knownCasesKeepTheirClassification() {
        #expect(SSHError.map(ChannelError.eof).isConnectionFailed)
        #expect(SSHError.map(SSHClientError.allAuthenticationOptionsFailed).isAuthenticationFailed)
        #expect(SSHError.map(SSHError.handshakeFailed).isHandshakeFailed)
    }

    @Test("The existing-channel authentication gate's EOF and timeout have explicit classifications")
    func authenticationGateFailuresAreClassified() {
        let closed = SSHError.map(SSHChannelAuthentication.Failure.connectionClosed)
        let timedOut = SSHError.map(SSHChannelAuthentication.Failure.timedOut)
        #expect(closed.isHandshakeFailed)
        #expect(timedOut.isConnectionFailed)
        let wrapped = ConnectionFailure(SSHError.underlying(SSHChannelAuthentication.Failure.connectionClosed))
        #expect(wrapped.message == SSHError.handshakeFailed.description)
        #expect(wrapped.recovery == .retry)
    }

    @Test("Cloudflare setup preserves a typed first failure when SSH reports only EOF or an opaque error")
    func carrierFailureSurvivesOpaqueSSHFailure() {
        let original: [any Error] = [
            SSHChannelAuthentication.Failure.connectionClosed,
            ChannelError.eof,
            SSHError.sessionClosed,
            CloudflareSSHTransportError.connectionClosed,
            SSHError.underlying(OpaqueError(description: "private-token https://private.invalid/path")),
        ]
        let failures: [CloudflareSSHTransportError] = [
            .tlsFailure(.certificateRejected), .heartbeatTimedOut, .socketFailure(code: 54), .httpStatus(401),
        ]
        for error in original {
            for transport in failures {
                let recovered = SSHError.preservingCloudflareSetupCause(error,
                    firstTermination: .failed(transport), firstFailure: transport)
                #expect(recovered as? CloudflareSSHTransportError == transport)
                #expect(ConnectionFailure(recovered) == ConnectionFailure(transport))
                #expect(!ConnectionFailure(recovered).message.contains("private"))
                #expect(!ConnectionFailure(recovered).message.contains("https://"))
            }
        }
    }

    @Test("Remote EOF and WebSocket close codes preserve closure without guessing Access policy")
    func remoteClosureIsNotAnAuthenticationVerdict() {
        let events: [CloudflareSSHDiagnosticEvent.Kind] = [
            .transportEOF, .peerClose(code: nil), .peerClose(code: 1000), .peerClose(code: 1008), .peerClose(code: 1011),
        ]
        for event in events {
            let recovered = SSHError.preservingCloudflareSetupCause(
                SSHChannelAuthentication.Failure.connectionClosed, firstTermination: event,
                firstFailure: .tlsFailure(.connectionClosed))
            #expect(recovered as? CloudflareSSHTransportError == .connectionClosed)
            #expect(ConnectionFailure(recovered).recovery == .retry)
        }
    }

    @Test("Explicit SSH authentication, host-key, cancellation and Access decisions outrank carrier cleanup")
    func explicitFailuresTakePrecedence() {
        let originals: [any Error] = [
            SSHClientError.allAuthenticationOptionsFailed,
            SSHClientError.unsupportedPasswordAuthentication,
            SSHError.authenticationFailed,
            SSHError.authMethodRejected,
            SSHError.credentialUnavailable,
            HostKeyRejected(), CancellationError(), URLError(.cancelled),
            CloudflareAuthError.loginRequired, AccessError.expiredToken,
            CloudflareSSHTransportError.httpStatus(403),
            SSHChannelAuthentication.Failure.timedOut,
        ]
        for original in originals {
            for error in [original, SSHError.underlying(original)] {
                let recovered = SSHError.preservingCloudflareSetupCause(error,
                    firstTermination: .failed(.tlsFailure(.connectionClosed)),
                    firstFailure: .tlsFailure(.connectionClosed))
                #expect(ConnectionFailure(recovered) == ConnectionFailure(error))
                #expect(!(recovered is CloudflareSSHTransportError)
                    || (recovered as? CloudflareSSHTransportError) == .httpStatus(403))
            }
        }
    }

    @Test("A local close or cancellation cannot become a later carrier cleanup error")
    func cleanupCannotReplaceOriginalCause() {
        let original = OpaqueError(description: "private-token https://private.invalid/path")
        for event in [CloudflareSSHDiagnosticEvent.Kind.localCloseRequested, .cancelled] {
            let recovered = SSHError.preservingCloudflareSetupCause(original,
                firstTermination: event, firstFailure: .tlsFailure(.connectionClosed))
            #expect(recovered is OpaqueError)
            #expect(ConnectionFailure(recovered) == ConnectionFailure(original))
        }
        let withoutEvidence = SSHError.preservingCloudflareSetupCause(original,
            firstTermination: nil, firstFailure: nil)
        #expect(withoutEvidence is OpaqueError)
        #expect(!ConnectionFailure(withoutEvidence).message.contains("private"))
    }

    @Test("the detail survives for logs even when the alert stays plain")
    func diagnosticKeepsTheDetail() {
        let raw = OpaqueError(description: "Citadel.ClientHandshakeHandler $105f91dd4")
        let mapped = SSHError.underlying(raw)
        #expect(!mapped.description.contains("Citadel"))
        #expect(mapped.diagnostic.contains("Citadel"))
    }

    /// Anything that reaches the user must be a sentence, not a dump. This is
    /// the guard that would have caught the original defect: it does not care
    /// which case an error maps to, only that what is shown is presentable.
    @Test("no mapped message exposes internals")
    func messagesArePresentable() {
        let samples = [
            "Citadel.ClientHandshakeHandler.(unknown context at $105f91dd4).Disconnected error 1.",
            "Connection refused",
            "NIOSSH.SSHClientError.allAuthenticationOptionsFailed",
            "channelCreationFailed",
        ]
        for text in samples {
            let message = SSHError.map(OpaqueError(description: text)).description
            #expect(!message.contains("$"), "leaks a pointer: \(message)")
            #expect(!message.lowercased().contains("unknown context"),
                    "leaks internals: \(message)")
        }
    }

    @Test("Transport preflight failure is correlated and never exports an untrusted route")
    func transportPreflightDiagnostics() async {
        let recorder = ConnectionDiagnosticRecorder()
        let service = diagnosticService(recorder)
        var connection = diagnosticConnection()
        let privateRoute = "https://private.invalid/path?token=private-token"
        connection.transportRaw = privateRoute
        do {
            _ = try await service.connect(connection)
            Issue.record("Invalid transport unexpectedly connected")
        } catch {
            // Instrumentation must preserve the old preflight error type.
            #expect(error as? ConnectionTransportError == .unsupportedTransport(privateRoute))
        }
        let events = recorder.events
        #expect(events.map(\.phase) == [.transportValidation, .transportValidation])
        #expect(events.map(\.outcome) == [.started, .failed])
        #expect(events.last?.errorClass == "transport.invalid-configuration")
        #expect(events.allSatisfy { $0.route == nil && $0.connectionID == connection.id })
        #expect(Set(events.map(\.attemptID)).count == 1)
        #expect(events.allSatisfy { $0.message.contains("route=unknown phase=transport-validation") })
        assertPrivateFieldsAbsent(events, connection: connection, extra: [privateRoute, "private-token"])
    }

    @Test("Missing Access login records its preflight stage before any SSH credential read")
    func cloudflareAccessPreflightDiagnostics() async {
        let recorder = ConnectionDiagnosticRecorder()
        let service = diagnosticService(recorder)
        var connection = diagnosticConnection()
        connection.selectTransport(.cloudflareSSH)
        do {
            _ = try await service.connect(connection)
            Issue.record("Missing Access credentials unexpectedly connected")
        } catch {
            #expect(error as? CloudflareAuthError == .loginRequired)
        }
        let events = recorder.events
        #expect(events.map(\.phase) == [.transportValidation, .cloudflareAccess, .cloudflareAccess])
        #expect(events.map(\.outcome) == [.started, .started, .failed])
        #expect(events.last?.errorClass == "cloudflare-auth.login-required")
        #expect(events.allSatisfy { $0.route == .cloudflareSSH && $0.connectionID == connection.id })
        #expect(Set(events.map(\.attemptID)).count == 1)
        assertPrivateFieldsAbsent(events, connection: connection)
    }

    @Test("SSH credential and key parsing failures have separate stages and per-call attempt IDs")
    func credentialPreflightDiagnostics() async {
        let recorder = ConnectionDiagnosticRecorder()
        let service = diagnosticService(recorder)
        var connection = diagnosticConnection()
        do {
            _ = try await service.connect(connection)
            Issue.record("Missing SSH credentials unexpectedly connected")
        } catch {
            guard let ssh = error as? SSHError, case .missingKeychainRef = ssh else {
                Issue.record("Preflight error semantics changed")
                return
            }
        }
        let first = recorder.events
        #expect(first.map(\.phase) == [.transportValidation, .sshCredential, .sshCredential])
        #expect(first.last?.errorClass == "ssh.missing-keychain-ref")
        connection.authMethod = .key
        let privateKey = "private-key-and-passphrase-that-is-not-a-valid-PEM"
        do {
            _ = try await service.connect(connection, overrideSecret: privateKey)
            Issue.record("Malformed SSH key unexpectedly connected")
        } catch {}
        let second = Array(recorder.events.dropFirst(first.count))
        #expect(second.map(\.phase) == [.transportValidation, .sshCredential, .authenticationMethod, .authenticationMethod])
        #expect(second.last?.outcome == .failed)
        #expect(Set(second.map(\.attemptID)).count == 1)
        #expect(first.first?.attemptID != second.first?.attemptID)
        #expect(recorder.events.allSatisfy { $0.connectionID == connection.id })
        assertPrivateFieldsAbsent(recorder.events, connection: connection, extra: [privateKey])
    }

    @Test("Provider errors retain stage context without exporting raw descriptions or secrets")
    func providerFailureDiagnosticsArePrivate() async {
        let recorder = ConnectionDiagnosticRecorder()
        let service = diagnosticService(recorder)
        let connection = diagnosticConnection()
        do {
            _ = try await service.connect(connection, overrideSecret: "private-password")
            Issue.record("Throwing provider unexpectedly connected")
        } catch {}
        let events = recorder.events
        #expect(events.map(\.phase) == [.transportValidation, .sshCredential, .authenticationMethod,
                                       .transportDial, .directSSHConnect, .directSSHConnect])
        #expect(events.last?.outcome == .failed)
        #expect(events.last?.errorClass == "unclassified")
        #expect(Set(events.map(\.attemptID)).count == 1)
        #expect(events.allSatisfy { $0.message.hasPrefix("ssh[\($0.attemptID.uuidString)] conn=\(connection.id.uuidString) route=direct phase=") })
        assertPrivateFieldsAbsent(events, connection: connection,
            extra: ["private-password", "private-provider-token", "https://private.invalid/path"])
    }

    @Test("Typed failure classifications keep useful codes and redact arbitrary payloads")
    func diagnosticClassificationIsBounded() {
        #expect(SSHConnectionDiagnostic.classify(SSHError.unsupportedKeyType("private-key")) == "ssh.unsupported-key-type")
        #expect(SSHConnectionDiagnostic.classify(SSHError.underlying(AccessError.expiredToken)) == "access.expired-token")
        #expect(SSHConnectionDiagnostic.classify(CloudflareSSHTransportError.httpStatus(403)) == "cloudflare.http-403")
        #expect(SSHConnectionDiagnostic.classify(CloudflareSSHTransportError.tlsFailure(.certificateRejected)) == "cloudflare.tls-certificateRejected")
        #expect(SSHConnectionDiagnostic.classify(URLError(.timedOut, userInfo: [NSURLErrorFailingURLStringErrorKey: "https://private.invalid"])) == "url.code--1001")
        #expect(SSHConnectionDiagnostic.classify(OpaqueError(description: "private-token")) == "unclassified")
    }

    private func diagnosticConnection() -> ServerConnection {
        ServerConnection(name: "private-name", host: "private-host.invalid", port: 22,
                         username: "private-username", authMethod: .password)
    }

    private func diagnosticService(_ recorder: ConnectionDiagnosticRecorder) -> SSHService {
        SSHService(keychain: .inMemory(), hostKeyValidator: .inMemory(),
                   clientProvider: DiagnosticThrowingProvider(),
                   cloudflareAuth: CloudflareAccessAuth(keychain: .inMemory()),
                   onConnectionDiagnostic: { recorder.append($0) })
    }

    private func assertPrivateFieldsAbsent(_ events: [SSHConnectionDiagnostic],
                                          connection: ServerConnection, extra: [String] = []) {
        for field in [connection.host, connection.name, connection.username] + extra {
            #expect(events.allSatisfy { !$0.message.contains(field) })
        }
    }

    private struct DiagnosticThrowingProvider: SSHClientProvider {
        func connect(host: String, port: Int, authenticationMethod: SSHAuthenticationMethod,
                     hostKeyValidator: SSHHostKeyValidator) async throws -> SSHClient {
            throw OpaqueError(description: "private-provider-token https://private.invalid/path")
        }
        func connect(on channel: Channel, authenticationMethod: SSHAuthenticationMethod,
                     hostKeyValidator: SSHHostKeyValidator) async throws -> SSHClient {
            throw OpaqueError(description: "private-provider-token https://private.invalid/path")
        }
    }
}

private final class ConnectionDiagnosticRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [SSHConnectionDiagnostic] = []
    var events: [SSHConnectionDiagnostic] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }
    func append(_ event: SSHConnectionDiagnostic) {
        lock.lock()
        defer { lock.unlock() }
        recorded.append(event)
    }
}

private extension SSHError {
    var isAuthenticationFailed: Bool {
        if case .authenticationFailed = self { return true }
        return false
    }
    var isHandshakeFailed: Bool {
        if case .handshakeFailed = self { return true }
        return false
    }
    var isConnectionFailed: Bool {
        if case .connectionFailed = self { return true }
        return false
    }
}
