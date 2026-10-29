import Foundation
import TailcatSSH
import Testing
@testable import Moshpit

@Suite("Tailcat connection recovery", .serialized)
@MainActor
struct TailcatRecoveryTests {
    private func connection() -> ServerConnection {
        var connection = ServerConnection(name: "Tailcat recovery", host: "mac-mini", port: 22,
                                          username: "tester", authMethod: .password)
        connection.multiplexer = .none
        connection.selectTransport(.tailcat)
        connection.tailcatCredentialRef = TailcatCredentials.newReference()
        connection.tailcatServerPublicKey = "nodekey:" + String(repeating: "a", count: 64)
        return connection
    }

    @Test("Invalid or missing Tailcat credentials never enter automatic retry or browser login")
    func permanentFailureStopsRecovery() async {
        let errors: [any Error] = [TailcatSSHTransportError.invalidAddress,
                                  TailcatSSHTransportError.invalidClientKey,
                                  TailcatCredentialError.missingCredential,
                                  TailcatCredentialError.invalidStoredCredential]
        for error in errors {
            #expect(ConnectionFailure(error).recovery == .userAction)
            #expect(ConnectionFailure(SSHError.map(error)).recovery == .userAction)
            let script = DialScript { _ in throw error }
            let session = SessionHub.ActiveSession(connection: connection(), dial: script.dialer)
            await session.start(theme: .githubDark, fontSize: 14)
            await session.forceResume()
            await session.keepAlive()
            await session.connectionDropped(reason: "tailcat-regression")
            await session.reconnect()
            #expect(script.dials == 1)
            #expect(!session.viewModel.requiresAccessLogin)
            #expect(!session.viewModel.allowsAutomaticRetry)
            await session.stop()
        }
    }

    @Test("Missing tunnel credentials are detected before SSH credentials are requested")
    func preflightBeforeSSHAuthentication() async {
        let service = SSHService(keychain: .inMemory(), hostKeyValidator: .inMemory(),
                                 tailcatCredentials: TailcatCredentials(keychain: .inMemory()))
        do {
            _ = try await service.connect(connection())
            Issue.record("A missing Tailcat credential must not connect")
        } catch {
            #expect((error as? TailcatCredentialError) == .missingCredential)
        }
    }

    @Test("A dropped Tailcat shell shares one bounded retry across foreground and health callbacks")
    func droppedConnectionDoesNotSpin() async throws {
        #expect(ConnectionFailure(TailcatSSHTransportError.connectionClosed).recovery == .retry)
        let script = DialScript { connection in
            SSHSession(connection: connection, transport: SessionLifecycleTests.ScriptedTransport(.reply("")))
        }
        let session = SessionHub.ActiveSession(connection: connection(), dial: script.dialer)
        await session.start(theme: .githubDark, fontSize: 14)
        #expect(script.dials == 1)
        await session.connectionDropped(reason: "tailcat-synthetic-close")
        await session.forceResume()
        await session.keepAlive()
        #expect(script.dials == 1)
        for _ in 0..<180 {
            if script.dials > 1 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(script.dials == 2)
        #expect(session.shellWasReopened)
        await session.connectionDropped(reason: "tailcat-second-close")
        #expect(script.dials == 2)
        await session.stop()
    }
}
