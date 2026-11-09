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

    @Test("A long background return probes Tailscale SSH and preserves healthy sibling sessions")
    func longBackgroundProbesEachSSH() async throws {
        let hub = SessionHub(metrics: SessionMetricsRegistry())
        let healthy = SessionLifecycleTests.ScriptedTransport(.reply(""))
        let broken = SessionLifecycleTests.ScriptedTransport(.fail)
        let healthyScript = DialScript { SSHSession(connection: $0, transport: healthy) }
        let brokenScript = DialScript { SSHSession(connection: $0, transport: broken) }
        var first = connection()
        first.name = "healthy"
        var second = connection()
        second.name = "broken"
        hub.makeSession = { value in
            SessionHub.ActiveSession(connection: value,
                dial: value.id == first.id ? healthyScript.dialer : brokenScript.dialer)
        }
        let firstSession = hub.prepare(first)
        let secondSession = hub.prepare(second)
        await firstSession.start(theme: .githubDark, fontSize: 14)
        await secondSession.start(theme: .githubDark, fontSize: 14)
        await hub.resumeAll(force: true)
        #expect(healthy.commands.contains("true") && broken.commands.contains("true"),
                "each SSH peer must prove liveness independently of node status")
        #expect(firstSession.viewModel.status == .connected && healthyScript.dials == 1,
                "one failed peer must not tear down its healthy sibling")
        #expect(secondSession.viewModel.status == .reconnecting)
        await hub.disconnect(first.id)
        await hub.disconnect(second.id)
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
    final class ProbeTransport: SSHClientTransport, @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        private var ready = false
        private var pending: [CheckedContinuation<Data, Never>] = []
        private let base = SessionLifecycleTests.ScriptedTransport(.reply(""))
        var probes: Int { lock.withLock { count } }
        func run(_ command: String) async throws -> Data {
            guard command == "true" else { return Data() }
            return await withCheckedContinuation { continuation in
                let answer = lock.withLock {
                    count += 1
                    if ready { return true }
                    pending.append(continuation); return false
                }
                if answer { continuation.resume(returning: Data()) }
            }
        }
        func recover() {
            let waiters = lock.withLock { ready = true; let saved = pending; pending.removeAll(); return saved }
            for waiter in waiters { waiter.resume(returning: Data()) }
        }
        func openPTY(rows: Int, cols: Int, onOutput: @escaping @Sendable (Data) -> Void,
                     onEnd: @escaping @Sendable () -> Void) async throws -> any SSHPTYWriter {
            try await base.openPTY(rows: rows, cols: cols, onOutput: onOutput, onEnd: onEnd)
        }
        func shutdown() async { recover(); await base.shutdown() }
    }

    @Test("Path and timer checks cannot turn one slow probe into two failures")
    func overlappingProbesDoNotDropSession() async throws {
        let transport = ProbeTransport()
        let script = DialScript { SSHSession(connection: $0, transport: transport) }
        let session = SessionHub.ActiveSession(connection: connection(), dial: script.dialer)
        await session.start(theme: .githubDark, fontSize: 14)
        session.probeTimeout = 0.1
        let first = Task { await session.keepAlive() }
        for _ in 0..<100 where transport.probes == 0 { try await Task.sleep(for: .milliseconds(2)) }
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<8 { group.addTask { await session.keepAlive() } }
            group.addTask { await session.resumeIfNeeded(probeTimeout: 0.02) }
        }
        await first.value
        #expect(transport.probes == 1 && session.viewModel.status == .connected && script.dials == 1)
        await session.stop()
    }

    @Test("Tailscale gets a confirmation round trip after a single foreground timeout")
    func slowResumeCanRecoverWithoutRedial() async throws {
        let transport = ProbeTransport()
        let script = DialScript { SSHSession(connection: $0, transport: transport) }
        let session = SessionHub.ActiveSession(connection: connection(), dial: script.dialer)
        await session.start(theme: .githubDark, fontSize: 14)
        session.foregroundProbeTimeout = 0.03
        session.tailscaleResumeProbeDelay = .milliseconds(30)
        await session.resumeIfNeeded(probeTimeout: 0.03)
        #expect(session.viewModel.status == .connected && script.dials == 1)
        transport.recover()
        try await Task.sleep(for: .milliseconds(150))
        #expect(transport.probes >= 2 && session.viewModel.status == .connected && script.dials == 1)
        await session.stop()
    }

    @Test("Two confirmed silent probes still replace a dead SSH stream")
    func repeatedSilenceStillReconnects() async throws {
        let transport = ProbeTransport()
        let replacement = SessionLifecycleTests.ScriptedTransport(.reply(""))
        let count = SessionLifecycleTests.Counter()
        let script = DialScript { value in
            count.bump()
            return SSHSession(connection: value, transport: count.count == 1 ? transport : replacement)
        }
        let session = SessionHub.ActiveSession(connection: connection(), dial: script.dialer)
        await session.start(theme: .githubDark, fontSize: 14)
        session.tailscaleResumeProbeDelay = .seconds(10)
        await session.resumeIfNeeded(probeTimeout: 0.03)
        #expect(session.viewModel.status == .connected)
        await session.resumeIfNeeded(probeTimeout: 0.03)
        #expect(session.viewModel.status == .reconnecting)
        for _ in 0..<150 where script.dials < 2 || session.viewModel.status != .connected {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(script.dials == 2 && session.viewModel.status == .connected)
        await session.stop()
    }

    @Test("Inbound data arriving during a slow probe prevents a false disconnect")
    func trafficOutranksProbeTimeout() async throws {
        let transport = ProbeTransport()
        let script = DialScript { SSHSession(connection: $0, transport: transport) }
        let session = SessionHub.ActiveSession(connection: connection(), dial: script.dialer)
        await session.start(theme: .githubDark, fontSize: 14)
        session.probeTimeout = 0.08
        let check = Task { await session.keepAlive() }
        for _ in 0..<100 where transport.probes == 0 { try await Task.sleep(for: .milliseconds(2)) }
        session.noteInbound()
        await check.value
        await session.keepAlive()
        #expect(transport.probes == 1 && session.viewModel.status == .connected && script.dials == 1)
        await session.stop()
    }

}
