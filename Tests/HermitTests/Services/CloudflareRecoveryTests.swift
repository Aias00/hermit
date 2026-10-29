import CloudflareAccess
import CloudflareSSH
import Foundation
import Testing
@testable import Moshpit

@Suite("Cloudflare connection recovery", .serialized)
@MainActor
struct CloudflareRecoveryTests {
    private func connection() -> ServerConnection {
        var connection = ServerConnection(name: "Cloudflare recovery", host: "192.0.2.1", port: 22,
                                          username: "tester", authMethod: .password)
        connection.multiplexer = .none
        connection.selectTransport(.cloudflareSSH)
        connection.cloudflareHostname = "terminal.example.com"
        connection.cloudflareTeamDomain = "test.cloudflareaccess.com"
        connection.cloudflareAudience = "test-audience"
        return connection
    }

    @Test("Authentication, policy, TLS and SSH credential failures keep distinct recovery decisions")
    func failureClassification() {
        let cases: [(any Error, ConnectionFailure.Recovery)] = [
            (CloudflareSSHTransportError.httpStatus(401), .login),
            (CloudflareSSHTransportError.httpStatus(302), .login),
            (CloudflareSSHTransportError.httpStatus(403), .userAction),
            (CloudflareSSHTransportError.tlsFailure(.certificateRejected), .userAction),
            (CloudflareSSHTransportError.tlsFailure(.hostnameMismatch), .userAction),
            (CloudflareSSHTransportError.tlsFailure(.handshakeFailed), .userAction),
            (CloudflareSSHTransportError.tlsFailure(.connectionClosed), .retry),
            (SSHError.authenticationFailed, .userAction),
            (SSHError.credentialUnavailable, .userAction),
            (SSHError.authMethodRejected, .userAction),
            (CloudflareAuthError.loginRequired, .login),
            (CloudflareAuthError.cancelled, .userAction),
            (AccessError.expiredToken, .login),
            (CloudflareSSHTransportError.httpStatus(503), .retry),
            (CloudflareSSHTransportError.httpStatus(429), .retry),
            (CloudflareSSHTransportError.socketFailure(code: 61), .retry),
            (AccessError.networkFailure, .retry),
        ]
        for (error, expected) in cases {
            #expect(ConnectionFailure(error).recovery == expected)
            #expect(ConnectionFailure(SSHError.map(error)).recovery == expected)
        }
    }

    @Test("Backoff follows its bounded schedule and rejects early retries")
    func boundedBackoff() {
        var backoff = CloudflareReconnectBackoff()
        let start = Date(timeIntervalSince1970: 10_000)
        for (index, expected) in [1.0, 2, 4, 8, 15, 30, 30, 30].enumerated() {
            let now = start.addingTimeInterval(Double(index) * 60)
            #expect(backoff.failed(now: now, jitter: 1) == expected)
            #expect(!backoff.permitsAttempt(now: now))
            #expect(!backoff.permitsAttempt(now: now.addingTimeInterval(expected - 0.001)))
            #expect(backoff.permitsAttempt(now: now.addingTimeInterval(expected)))
        }
        for _ in 0..<10 { #expect(backoff.failed(now: start, jitter: 100) <= 30) }
    }

    @Test("A short-lived connection keeps backoff; thirty stable seconds resets it")
    func stableConnectionResetsBackoff() {
        var backoff = CloudflareReconnectBackoff()
        let start = Date(timeIntervalSince1970: 10_000)
        _ = backoff.failed(now: start, jitter: 1)
        _ = backoff.failed(now: start.addingTimeInterval(10), jitter: 1)
        backoff.succeeded(now: start.addingTimeInterval(20))
        #expect(backoff.permitsAttempt(now: start.addingTimeInterval(20)))
        #expect(backoff.failed(now: start.addingTimeInterval(49), jitter: 1) == 4)
        backoff.succeeded(now: start.addingTimeInterval(50))
        #expect(backoff.failed(now: start.addingTimeInterval(80), jitter: 1) == 1)
        #expect(backoff.failures == 1)
    }

    private func exerciseAutomaticEntries(_ session: SessionHub.ActiveSession) async {
        await session.start(theme: .githubDark, fontSize: 14, automatic: true)
        await session.keepAlive()
        await session.resumeIfNeeded(probeTimeout: 0.01)
        await session.forceResume()
        await session.connectionDropped(reason: "synthetic-regression")
        await session.reconnect()
        #expect(!(await session.retryIfDown(stalledDialAfter: 0, reason: "synthetic-path-change")))
        session.repinForeground()
        session.resumeHerdrFrames()
    }

    @Test("Permanent failures stop every automatic recovery entrance")
    func permanentFailuresDoNotRedial() async {
        let errors: [any Error] = [
            CloudflareSSHTransportError.httpStatus(403),
            CloudflareSSHTransportError.tlsFailure(.certificateRejected),
            SSHError.authenticationFailed,
            CloudflareAuthError.loginRequired,
        ]
        for error in errors {
            let script = DialScript { _ in throw error }
            let session = SessionHub.ActiveSession(connection: connection(), dial: script.dialer)
            await session.start(theme: .githubDark, fontSize: 14)
            #expect(script.dials == 1)
            #expect(!session.viewModel.allowsAutomaticRetry)
            await exerciseAutomaticEntries(session)
            #expect(script.dials == 1)
            #expect(!session.viewModel.isAutoReconnectInFlight)
            await session.stop()
        }
    }

    @Test("Missing Access credentials never trigger browser login from connect or recovery")
    func recoveryDoesNotPresentBrowser() async throws {
        let browserCalls = SessionLifecycleTests.Counter()
        let auth = CloudflareAccessAuth(keychain: .inMemory(), login: { _ in
            browserCalls.bump()
            throw CloudflareAuthError.cancelled
        }, validate: { credentials, _ in credentials })
        let configuration = connection()
        guard case .cloudflare(let settings) = try configuration.validatedTransport() else {
            Issue.record("expected Cloudflare fixture"); return
        }
        let script = DialScript { _ in
            _ = try await auth.credentials(settings: settings)
            throw SSHError.connectionFailed
        }
        let session = SessionHub.ActiveSession(connection: configuration, dial: script.dialer)
        await session.start(theme: .githubDark, fontSize: 14)
        #expect(session.viewModel.requiresAccessLogin)
        await exerciseAutomaticEntries(session)
        #expect(script.dials == 1)
        #expect(browserCalls.count == 0)
        await session.stop()
    }

    @Test("Cloudflare Shell connects without probing or starting Herdr, tmux or mosh")
    func shellHasNoMultiplexerDependency() async {
        let configuration = connection()
        let transport = SessionLifecycleTests.ScriptedTransport(.reply("/usr/bin/python3\n::Darwin::/opt/homebrew/bin/brew\n"))
        let script = DialScript { configuration in SSHSession(connection: configuration, transport: transport) }
        let session = SessionHub.ActiveSession(connection: configuration, dial: script.dialer)
        let sidecars = SessionLifecycleTests.Counter()
        session.sidecarConnect = { _ in sidecars.bump(); throw SSHError.connectionFailed }
        await session.start(theme: .githubDark, fontSize: 14)
        #expect(session.viewModel.status == .connected)
        #expect(transport.commands.contains(HostCapabilities.probeCommand(for: .none)))
        for command in transport.commands {
            #expect(!command.contains("herdr"))
            #expect(!command.contains("tmux"))
            #expect(!command.contains("mosh-server"))
        }
        #expect(sidecars.count == 0)
        #expect(session.tmuxController == nil)
        #expect(session.herdrControl == nil)
        #expect(session.degrade == nil)
        await session.stop()
    }

    @Test("Brief successful sessions also wait for backoff after dropping")
    func successfulDropDoesNotSpin() async throws {
        let script = DialScript { configuration in
            SSHSession(connection: configuration, transport: SessionLifecycleTests.ScriptedTransport(.reply("")))
        }
        let session = SessionHub.ActiveSession(connection: connection(), dial: script.dialer)
        await session.start(theme: .githubDark, fontSize: 14)
        #expect(script.dials == 1)
        await session.connectionDropped(reason: "synthetic-immediate-close")
        await session.forceResume()
        await session.keepAlive()
        #expect(script.dials == 1, "Path/foreground callbacks must share the pending delay")
        for _ in 0..<180 {
            if script.dials > 1 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(script.dials == 2)
        #expect(session.shellWasReopened)
        await session.connectionDropped(reason: "synthetic-second-close")
        #expect(script.dials == 2, "A short success must not clear the backoff history")
        await session.stop()
        try await Task.sleep(for: .milliseconds(20))
        #expect(script.dials == 2)
    }

    @Test("A manual attempt retires the previous attempt's queued retry")
    func manualStartCancelsOldTimer() async throws {
        let script = DialScript { _ in throw SSHError.connectionFailed }
        let session = SessionHub.ActiveSession(connection: connection(), dial: script.dialer)
        await session.start(theme: .githubDark, fontSize: 14)
        script.behavior = { configuration in
            SSHSession(connection: configuration, transport: SessionLifecycleTests.ScriptedTransport(.reply("")))
        }
        await session.start(theme: .githubDark, fontSize: 14)
        #expect(script.dials == 2)
        try await Task.sleep(for: .milliseconds(1350))
        #expect(script.dials == 2)
        #expect(session.viewModel.status == .connected)
        #expect(!session.shellWasReopened)
        await session.stop()
    }
}
