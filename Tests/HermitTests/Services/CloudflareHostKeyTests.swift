import Foundation
import Testing
@testable import Moshpit

@Suite("Cloudflare host-key decisions", .serialized)
@MainActor
struct CloudflareHostKeyTests {
    @Test("Rejecting a host key stops retries before a delayed library timeout", arguments: [false, true])
    func rejectionSurvivesDelayedTimeout(changed: Bool) async throws {
        var configuration = ServerConnection(name: "host-key", host: "logical.example.com", port: 22,
                                             username: "test", authMethod: .password)
        configuration.multiplexer = .none
        configuration.selectTransport(.cloudflareSSH)
        configuration.cloudflareHostname = "ssh.example.com"
        configuration.cloudflareTeamDomain = "test.cloudflareaccess.com"
        configuration.cloudflareAudience = "test-audience"
        let gate = DialGate()
        let calls = SessionLifecycleTests.Counter()
        let session = SessionHub.ActiveSession(connection: configuration, dial: { connection, unknown, replacement in
            calls.bump()
            let trusted = changed
                ? await replacement(connection.host, connection.port, "new-fingerprint", "old-fingerprint")
                : await unknown(connection.host, connection.port, "new-fingerprint")
            #expect(!trusted)
            // The underlying SSH library can return a generic timeout much
            // later than the user's decision. It must not erase that decision.
            return try await gate.wait().get()
        })
        let attempt = Task { await session.start(theme: .githubDark, fontSize: 14) }
        for _ in 0..<200 {
            if session.viewModel.hostKeyPrompt != nil { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        let prompt = try #require(session.viewModel.hostKeyPrompt)
        prompt.decide(false)
        #expect(!session.viewModel.allowsAutomaticRetry)
        #expect(session.viewModel.connectionFailure?.recovery == .userAction)
        await session.keepAlive()
        await session.forceResume()
        await session.reconnect()
        #expect(calls.count == 1)
        gate.finish(.failure(SSHError.connectionFailed))
        await attempt.value
        #expect(session.viewModel.connectionFailure?.recovery == .userAction)
        #expect(session.viewModel.errorMessage == ConnectionFailure(HostKeyRejected()).message)
        // SwiftUI dismissal and a tap may both hold the same old closure.
        prompt.decide(true)
        #expect(!session.viewModel.allowsAutomaticRetry)
        await session.stop()
    }

    @Test("Unknown library errors cannot expose raw diagnostic URLs to terminal UI")
    func diagnosticsStayOutOfUI() {
        let failure = NSError(domain: "https://example.invalid/private-capability", code: 7,
                              userInfo: [NSLocalizedDescriptionKey: "private-implementation-detail"])
        let message = ConnectionFailure(SSHError.underlying(failure)).message
        #expect(!message.contains("private"))
        #expect(!message.contains("https://"))
        #expect(ConnectionFailure(failure).recovery == .retry)
    }
}
