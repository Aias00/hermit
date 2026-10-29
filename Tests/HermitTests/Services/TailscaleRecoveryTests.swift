import Foundation
import TailscaleSSH
import Testing
@testable import Moshpit

@Suite("Tailscale connection recovery", .serialized)
@MainActor
struct TailscaleRecoveryTests {
    private func connection() -> ServerConnection {
        var value = ServerConnection(name: "Tailscale recovery", host: "mac-mini", port: 22,
                                     username: "tester", authMethod: .password)
        value.multiplexer = .none
        value.selectTransport(.tailscale)
        value.tailscaleAccountID = UUID().uuidString.lowercased()
        return value
    }

    @Test("Account errors stop recovery without opening a Cloudflare or Tailscale login browser")
    func accountFailureStopsRecovery() async {
        let errors: [any Error] = [TailscaleAccountError.loginRequired, TailscaleAccountError.accountMismatch,
                                  TailscaleAccountError.approvalRequired, TailscaleAccountError.peerUnavailable,
                                  TailscaleSSHTransportError.invalidStoredState]
        for error in errors {
            #expect(ConnectionFailure(error).recovery == .userAction)
            #expect(ConnectionFailure(SSHError.map(error)).recovery == .userAction)
            let script = DialScript { _ in throw error }
            let session = SessionHub.ActiveSession(connection: connection(), dial: script.dialer)
            await session.start(theme: .githubDark, fontSize: 14)
            await session.forceResume()
            await session.keepAlive()
            await session.connectionDropped(reason: "tailscale-regression")
            #expect(script.dials == 1)
            #expect(!session.viewModel.requiresAccessLogin)
            #expect(!session.viewModel.allowsAutomaticRetry)
            await session.stop()
        }
        #expect(ConnectionFailure(TailscaleSSHTransportError.connectionClosed).recovery == .retry)
        #expect(ConnectionFailure(TailscaleAccountError.starting).recovery == .retry)
    }

    @Test("Missing account is reported before reading SSH keys or dialing directly")
    func accountPreflightBeforeSSH() async {
        let vault = TailscaleAccountVault(backend: InMemoryKeychainBackend())
        let runtime = TailscaleRuntime(vault: vault, factory: { _ in
            Issue.record("Missing account must never construct a native node")
            throw TailscaleAccountError.loginRequired
        })
        let service = SSHService(keychain: .inMemory(), hostKeyValidator: .inMemory(), tailscaleRuntime: runtime)
        await #expect(throws: TailscaleAccountError.loginRequired) { try await service.connect(connection()) }
    }
}
